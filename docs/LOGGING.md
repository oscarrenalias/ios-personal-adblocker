# Logging

The rules for logging in the app and its extensions. Every spec includes a
**Logging** section that points here and lists the events to log for that
change.

## Why

The tunnel runs in the background, inside an extension you can't attach a UI
to. When something goes wrong on a device, the logs are often the only way to
see what happened. New code should log enough that a problem can be traced
from the logs alone.

## API

- Use Apple's unified logging (`os.Logger`). Don't use `print` or `NSLog`.
- **Subsystem:** `net.renalias.adblocker`, the same for every target, so one filter
  shows everything.
- **Category:** the component, for example `tunnel`, `engine`, `upstream`,
  `network-dns`, `path`, `lists`, `settings`, `ui`, `notify`, `controls`.
- Log through the small `os.Logger` wrapper `Log`
  (`IBlockerKit/Shared/Log.swift`). Create one per component with
  `Log(category: "engine")` and call `error`, `notice`, `info` or `debug`.
  Messages are logged `privacy: .public`.
- Messages are autoclosures. Each level method checks
  `OSLog.isEnabled(type:)` first and skips building the message when that
  level isn't being collected, so a per-query `debug` call with string
  interpolation costs only the check.

`PacketTunnelProvider` logs under category `tunnel` (and `path` for network
path changes) using the same wrapper.

## Levels

| Level | Use for | Examples |
|---|---|---|
| `error` | Something failed that shouldn't have | upstream error, file can't be read, IPC message can't be decoded, settings can't be applied |
| `notice` | Important state changes, rare | tunnel start/stop, upstream switched, alternative resolver marked down or back up, old Quad9 URL replaced (category `settings`, once per process: `replaced old Quad9 URL https://9.9.9.9:5053/dns-query -> https://9.9.9.9/dns-query`) |
| `info` | Normal events, at most a few per minute | network path changed (old → new interface), rules reloaded (with counts), list refresh result |
| `debug` | Per-query and step-by-step detail | each lookup's verdict and which upstream answered it, upstream timing, raw `dns_sd` results, retry decisions |

- **Never log per query above `debug`.** There can be hundreds of lookups a
  minute. By default on iOS, `info` messages are kept in memory only (visible
  while streaming) and `notice` and `error` are persisted to disk, so
  logging every query at `notice` or above costs battery and storage.
- Log **both sides** of anything that can fail or hang: started → succeeded
  or failed, with the duration where it matters (upstream queries, list
  downloads).
- Errors include the reason (error code or message) and enough context to act
  on: which upstream, which interface, which file.

## Privacy

- Domain names and IP addresses reveal browsing activity. Log them **only at
  `debug` level**, marked `privacy: .public`. Debug messages are kept in memory
  only and are visible while streaming logs; they aren't written to disk.
  Verbose mode (below) re-emits them at `info`, which is also in-memory only
  with the device's default logging configuration, so domain names stay out
  of persisted logs.
- At `info` and above, don't log domain names. Log counts, types, states and
  error codes instead.
- Resolver names and URLs (Cloudflare, `https://1.1.1.1/dns-query`) and
  interface names (`en0`, `pdp_ip0`) aren't personal. Log them `.public` at
  any level.

### The `notify` category

Status notifications (policy, poster, tunnel and app triggers) log under
`notify`. Kinds, delays and errors only, never domain names or URLs.

| Level | Events |
|---|---|
| `notice` | `scheduled <kind> in N s`; `posted restored for <kind>`; `authorization requested: granted/denied`; `stop classified expected/unexpected: reason <name>, user-off marker set/clear`; `user-off marker set: stop reason userInitiated`; `user-off marker cleared: tunnel started` |
| `info` | `suppressed <kind>: <reason>` (master off, type disabled, rate-limited, already notified this episode, not authorized); `cancelled pending <kind> (cleared after N s)`; `opened from notification kind <kind> -> <tab>`; `resolver episodes dismissed: alternative turned off`; `ignored status change from replaced router`; `tunnel-gone check: <result>`; `<kind> episode ended (list <id>)` |
| `error` | `authorization request failed`; `add failed for <kind>` |
| `debug` | policy trace (inputs and outcome of each decision), `no problem/restore content for <kind>`, deferred degraded notification, deferred or retried tunnel start notification, `list-rejected not notified: user-triggered run` |

### The `controls` category

The Control Center pause buttons (`PauseIntent`, in the Widgets extension) log
under `controls`, using `os.Logger` directly because the extension doesn't use
the `Log` wrapper. `<label>` is `pause button N min`. Times are local
wall-clock only; no domain names.

| Level | Events |
|---|---|
| `notice` | `<label>: paused until <time>` |
| `info` | `<label> ignored: protection off`; `<label>: replaced pause ending <time>` |
| `error` | `<label>: shared settings unavailable` |

### The `cache` category

The tunnel's DNS cache (`DNSCache`) logs under `cache`. Domain names appear
only at `debug`; `info` and above log counts, sizes and reasons.

| Level | Events |
|---|---|
| `notice` | `cache cleared (<reason>): N entries`; reasons are `resolver change`, `resolver status change`, `network change`, `user` |
| `info` | `cache evicted N entries (entry limit)` / `(byte limit)`, throttled to once a minute; `cache: N entries, N KB, hit rate N% (hits, misses), evicted N`, every 10 minutes when there was traffic |
| `debug` | `hit <name> <type>, ttl left N s`; `miss <name>` and `miss <name>: expired` / `stored response unusable`; `stored <name> <type>, ttl N s`; `not cached <name>: <reason>`; `cache purged N expired entries`; `not cached ...: cache cleared while in flight` |

The tunnel also logs `IPC clearDNSCache` (`tunnel`, `info`) and the app logs
`clearDNSCache requested` (`notice`) or `clearDNSCache failed: ...` (`error`).

### Maintenance and signals

The tunnel's maintenance loop (`tunnel` category) and the Darwin signals
between app and tunnel (`ipc` category). No domain names.

| Level | Events |
|---|---|
| `notice` | `maintenance interval N s (idle)` / `(degraded)`: at start and whenever the interval changes; `list exceptions generation A ≠ blocklist B, deferring reload` on each check until the generations match; `blocklist v1 loaded (no attribution); waiting for recompile` once per load of a v1 blob |
| `info` | `maintenance: N passes (timer N, settings N, blocklist N)`, at most every 10 minutes; `blocklist reloaded: N rules, generation G` with ` (signal)` appended when a signal triggered the check |
| `error` | `maintenance signal observer failed, timer only: <error>` (the tunnel falls back to timer passes) |
| `debug` | `signal received: settingsChanged` / `blocklistChanged` (tunnel); `signal posted: <signal name>` (`ipc`, app side); `flushQueryLog requested` / `skipped: tunnel not connected` (`ipc`) |

`flushQueryLog failed: ...` and `ipc <request>: ...` failures are `error` in
the `ipc` category.

## Reading the logs

- **Console.app on the Mac:** connect the iPhone, select it in the sidebar,
  click **Start**, and turn on **Action ▸ Include Info Messages** and
  **Include Debug Messages**. In the search field, type
  `subsystem:net.renalias.adblocker` and press Return to create a filter token. If
  needed, click the token's left part and choose **Subsystem**. Add more
  tokens (for example `category:network-dns`) to narrow it; tokens combine
  with AND. To see Subsystem and Category, right-click the column header and
  add those columns.
- **After installing a new build, turn protection off and on once.** iOS can
  keep the previous tunnel extension process running after an install from
  Xcode. It then keeps logging with the old code, and messages from the new
  code won't appear.
- **Nothing under the subsystem filter?** Filter on `process:PacketTunnel`
  instead. If messages show there but not under `subsystem:net.renalias.adblocker`, the
  running tunnel is an old build (see the previous point).
- **Xcode:** messages from the app show in the debug console while running
  from Xcode. For the tunnel extension, use Console.app, since the extension
  runs in its own process.

## Streaming from the command line (recommended)

The most reliable way to see the tunnel's logs, including `debug`, with no
admin rights and no logging profile, is
[pymobiledevice3](https://github.com/doronz88/pymobiledevice3), run through
`uvx`:

```bash
xcrun devicectl list devices          # find the iPhone's UDID
uvx pymobiledevice3 syslog live --udid <UDID> -m PacketTunnel
```

`-m PacketTunnel` keeps only the tunnel process. Our own lines show as
`PacketTunnel{PacketTunnel.debug.dylib}`. Debug messages appear while the
stream is running. To capture a fixed window to a file for analysis:

```bash
perl -e 'alarm 180; exec @ARGV' uvx pymobiledevice3 syslog live --udid <UDID> -m PacketTunnel > capture.log
```

## Seeing debug messages on a device

iOS doesn't record `debug` messages for our subsystem by default, and a
logging configuration profile (`com.apple.system.logging`) may be rejected by
the device. Use the in-app switch instead:

1. Turn on **Settings ▸ Privacy ▸ Verbose logging (1 hour)**. It turns itself
   off after an hour. The app posts a settings-changed signal, so the tunnel
   picks the change up within about 2 s, with no restart. If the signal is
   missed, the next 60 s maintenance pass applies it.
2. Stream in Console.app with **Action ▸ Include Info Messages** on and filter
   on `subsystem:net.renalias.adblocker`.
3. Look for lines prefixed `[verbose]`. These are the `debug` messages
   (per-query verdicts, network-dns query start/complete, upstream errors),
   emitted at `info` level while verbose mode is on.

The tunnel logs a `notice` when verbose mode turns on or off (with the expiry
time), and so does the app when the toggle changes.

## In specs

Every spec has a `## Logging` section that:

1. Links to this file.
2. Lists the specific events the change must log, with their levels.

Add an acceptance criterion that the listed events are logged at the stated
levels. The reviewer checks it.
