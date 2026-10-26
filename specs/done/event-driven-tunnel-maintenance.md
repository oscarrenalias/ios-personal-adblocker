---
name: Event-driven tunnel maintenance
id: spec-b210a0b5
description: Replace the 2 s tunnel maintenance loop with Darwin-notification signals plus a 60 s safety timer (KI-4)
dependencies: null
priority: medium
complexity: null
status: done
tags:
- tunnel
- battery
- ki-4
scope:
  in: null
  out: null
feature_root_id: B-82631cd4
---
# Event-driven tunnel maintenance

## Objective

Stop the packet tunnel from waking up every 2 seconds when nothing is
happening (KI-4 in `docs/KNOWN-ISSUES.md`). Other processes tell the tunnel
when shared state changes, using Darwin notifications, so the tunnel doesn't
have to poll for it. A slow 60-second timer stays as a safety net. The
2-second rhythm is used only while the tunnel is recovering from a degraded
start.

Visible behaviour must not change. Pauses from widgets, Control Center and
Shortcuts still take effect within about 2 seconds, and a background list
refresh still reaches the tunnel. The query log still updates live while the
Log tab is open.

## Today

`PacketTunnelProvider.startMaintenance` (`ios/PacketTunnel/PacketTunnelProvider.swift`, around line 552) loops every 2 s and does the following:

1. `engine.flush()`: writes pending query log records and `stats.json` (only
   if the stats changed).
2. Re-reads `SharedSettings`: `pausedUntil` (written by the widget/Control
   Center `PauseIntent` in `ios/Widgets/PauseControls.swift` and by
   `VPNControl.pause/resume`, which can't always reach the tunnel over IPC),
   then `verboseLoggingUntil`, and calls `notifier.retryDeferredStart()`.
3. While `recovery.isDegraded`: retries reading settings and the blocklist and
   re-applies them (`TunnelRecovery`).
4. Every 5th tick (10 s): opens `blocklist.bin` and reloads the matcher if its
   generation changed. This is the only way a list refresh in the background
   (`ListRefreshScheduler` and `BlocklistCompiler`, with no `RootView`, so no
   `reloadRules` IPC) reaches the tunnel.

Two things read files without asking the tunnel first:
- `QueryLogViewModel` (`IBlockerUI/Log/QueryLogViewModel.swift`) polls
  `querylog.ring` at 1 Hz while the Log tab is visible. It depends on the 2 s
  flush to see new records. The ring writer also flushes on its own after
  128 pending records.
- Widgets read `stats.json`. Their timelines refresh every few minutes at
  most, so a 60 s flush is fine for them.

The Dashboard and Settings already call `getStats`, which flushes first.

## Changes

### 1. Darwin notification signals (IBlockerKit/Shared)

Add a small `TunnelSignal` type in `IBlockerKit/Shared/TunnelSignal.swift`:

- Two names:
  - `net.renalias.adblocker.settings-changed`
  - `net.renalias.adblocker.blocklist-changed`
- `TunnelSignal.post(_:)`: posts through the Darwin notify center
  (`CFNotificationCenterGetDarwinNotifyCenter()` or `notify_post`). It works
  from the app, widget and tunnel processes.
- An observer type that registers for a signal and delivers each one to a
  Swift closure, then unregisters when it is released or cancelled. The
  callback has to be C-compatible: no captured context. Route it to the
  closure safely, for example through a registry keyed by name, or with
  `notify_register_dispatch`.

Darwin notifications carry no payload. The receiver re-reads the shared state
itself.

**Posting:**
- `SharedSettings`: post `settings-changed` after writing `pausedUntil` or
  `verboseLoggingUntil`. This covers `PauseIntent`, `VPNControl`,
  `TunnelController` and `SettingsView` in one place. The tunnel's own
  `setPause` IPC handler also writes `pausedUntil`. The signal it gets back
  is harmless, because the settings step is idempotent and
  `pauseDeadlineChanged` already ignores unchanged deadlines.
- `BlocklistCompiler.compile`: post `blocklist-changed` once, after all three
  `CompiledBlocklist.write` calls (block, user allow, user deny) succeed.
  Never post between writes, or the tunnel could load the new blocklist with
  stale user lists. Those lists share the generation, so later generation
  checks would never pick them up. A failed write posts nothing. This covers
  both foreground and background compiles.

### 2. Tunnel maintenance loop

Replace the fixed 2 s loop with one maintenance task that sleeps until the
first of these happens:

- **The timer expires.** It runs every 2 s while `recovery.isDegraded`, and
  every 60 s otherwise.
- **A `settings-changed` signal arrives.**
- **A `blocklist-changed` signal arrives.**

The task runs one pass at a time. Signals that arrive during a pass are
coalesced into a single follow-up pass, so passes never run concurrently.
Each pass knows why it woke up:

| Wake reason | Work |
|---|---|
| timer (idle, 60 s) | flush; settings step; blocklist generation check |
| timer (degraded, 2 s) | flush; settings step; recovery step (as today); blocklist generation check every 5th degraded tick, as today |
| settings-changed | settings step only |
| blocklist-changed | blocklist generation check only (reload if the generation differs) |

The steps keep today's code and behaviour: the settings step is block 2
above, the recovery step is block 3, and the generation check is block 4,
including its rate-limited error logging. Timer rules:
- Signal passes don't move the timer deadline. A steady stream of signals
  can't put off the flush or the generation check.
- Only timer passes advance the degraded tick counter, which drives "every
  5th".
- Moving between degraded and idle recomputes the next deadline from the
  current time.
- While `verboseLoggingUntil` is set, the next timer wake is the earlier of
  the interval and the deadline (plus a small margin). Verbose logging still
  turns off within about 2 s of expiring, as `docs/LOGGING.md` promises.
  Nothing writes the setting at expiry, so no signal fires.

Extract the wake decision into a
pure, testable type, for example `MaintenanceSchedule` in IBlockerKit. Given
the degraded state and the wake reason, it returns the next interval and the
steps to run.

When the tunnel stops (`stopTunnel`), cancel the observers along with the
task. The final flush at shutdown stays.

### 3. Query log and Dashboard chart stay live

Add an IPC request `flushLog` (`TunnelIPC.swift`). It calls `engine.flush()`
and returns `.ok`. Add `TunnelController.flushQueryLog()`.

Two views poll `QueryLogViewModel` at 1 Hz: the Log tab (`QueryLogView`) and
the Dashboard chart (`StatsChartView`, line 69).
- `poll()` becomes async. Before reading the ring, it awaits a flush hook that
  `RootView` sets, the same way it sets `onRulesChanged`.
- The hook sends `flushLog` at most once every 2 s, so a poll every second
  doesn't mean an IPC every second.
- If the tunnel isn't connected, skip the flush and read the ring as today.
- `StatsChartView` also calls `log.stopPolling()` in `onDisappear`, as
  `QueryLogView` does. Today the polling never stops once the Dashboard has
  appeared. Polling must keep running while either view is visible: make
  start/stop reference-counted, or use an equivalent approach.

New queries appear in the Log tab and the Dashboard chart within about 2 s,
as they do today.

### 4. Docs

Update KI-4 in `docs/KNOWN-ISSUES.md`: mark it fixed and describe the new
schedule. Update `docs/ARCHITECTURE.md` wherever it describes the 2 s
maintenance loop. In `docs/LOGGING.md`, keep the verbose-logging "about 2 s"
wording accurate and document the new log lines from the Logging section.

## Logging

Follow `docs/LOGGING.md` (subsystem `net.renalias.adblocker`, via `Log`).

- `tunnel`, **notice**: `maintenance interval <n> s (<degraded|idle>)` when the
  interval changes, including the first value at start.
- `tunnel`, **debug**: `signal received: <settings-changed|blocklist-changed>`.
- `tunnel`, **info**: the existing `blocklist reloaded: …` line. When the
  blocklist signal triggered the reload, add `(signal)`.
- `tunnel`, **info**, every 10 min: `maintenance: <n> passes (timer <a>,
  settings <b>, blocklist <c>)`, so wake-ups can be counted from device logs.
- `ipc`, **debug**: `signal posted: <name>` in the posting process.
- `tunnel`, **error**: failure to register a signal observer (the loop goes on
  with the timer only).

## Acceptance Criteria

1. When idle (not degraded, no signals), the tunnel runs at most one
   maintenance pass per 60 s. Verified by a unit test of the schedule type,
   and on device by the 10-minute summary line showing about 10 timer passes.
2. While degraded, the tunnel keeps the 2 s interval, and recovery behaves as
   today. Existing `TunnelRecovery` tests still pass.
3. A pause set from a Control Center pause button or a widget takes effect in
   the tunnel within 2 s: a blocked site loads, and the "pause ended"
   notification still arrives at the deadline. Resuming works the same way.
4. A blocklist compiled while the app is in the background reaches the tunnel
   within 2 s of the compile, through `blocklist-changed`. The 60 s timer
   catches it even if the signal is lost.
5. Turning on verbose logging in Settings applies in the tunnel within 2 s.
6. With the Log tab or the Dashboard open, new queries appear in the log and
   the chart within about 2 s. The app sends `flushLog` at most once every
   2 s, and stops polling when neither view is visible.
6a. Verbose logging turns off in the tunnel within about 2 s of its deadline,
   even when the tunnel is idle. Covered by a schedule unit test.
6b. `MaintenanceSchedule` unit tests cover the timer rules:
   - signal passes don't move the timer deadline;
   - signal passes don't advance the degraded tick counter;
   - moving between degraded and idle recomputes the deadline;
   - the verbose deadline shortens the wake.
6c. A compile posts `blocklist-changed` exactly once, after all three writes,
   and a failed compile posts nothing. Covered by a unit test.
7. `TunnelSignal` has a unit test: an observer receives a posted signal, and
   a cancelled observer receives nothing.
8. On device, with verbose logging on, Console.app (or `log stream`) filtered
   on `subsystem:net.renalias.adblocker` shows each line from the Logging
   section at its listed level. Check during an idle period, a Control Center
   pause, and a list refresh.
9. KI-4 is marked fixed in `docs/KNOWN-ISSUES.md`.

## Scope

**In:** the maintenance loop schedule, Darwin signals for settings and the
blocklist, the `flushLog` IPC and query log wiring, and the docs.

**Out:**
- Measuring battery use with Instruments (follow-up, by the user).
- Changing how often the Dashboard and Settings poll `getStats`. They poll
  only while visible.
- Widget refresh cadence.
- Any change to DNS handling, the cache or the resolver routing.

## Files to Add/Modify (hints)

| File | Change |
|---|---|
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelSignal.swift` | new: post/observe Darwin signals |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/MaintenanceSchedule.swift` | new: pure wake/interval/step decision |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/SharedSettings.swift` | post `settings-changed` on pause/verbose writes |
| `ios/IBlockerKit/Sources/IBlockerKit/Lists/BlocklistCompiler.swift` | post `blocklist-changed` after write |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelIPC.swift` | `flushLog` request |
| `ios/PacketTunnel/PacketTunnelProvider.swift` | new loop, observers, `flushLog` handler |
| `ios/IBlockerKit/Sources/IBlockerUI/System/TunnelController.swift` | `flushQueryLog()` |
| `ios/IBlockerKit/Sources/IBlockerUI/Log/QueryLogViewModel.swift`, `RootView.swift` | async poll, throttled flush hook, counted start/stop |
| `ios/IBlockerKit/Sources/IBlockerUI/Dashboard/StatsChartView.swift` | stop polling on disappear |
| `ios/IBlockerKit/Tests/IBlockerKitTests/…` | schedule and signal tests |
| `docs/KNOWN-ISSUES.md`, `docs/ARCHITECTURE.md`, `docs/LOGGING.md` | KI-4, loop description, new log lines |
