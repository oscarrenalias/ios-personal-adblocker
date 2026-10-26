---
name: Encryption state in widgets
id: spec-6b871430
description: Show DNS encryption state (encrypted / unencrypted / fallback / failing) in the status widget
dependencies: null
priority: medium
complexity: null
status: planned
tags:
- widgets
- resolver
scope:
  in: null
  out: null
feature_root_id: B-de1aa61b
---
# Encryption state in widgets

## Objective

The Home Screen and Lock Screen status widget (`ios/Widgets/StatusWidget.swift`)
should show whether DNS lookups are encrypted. The Dashboard status line
already shows this. That way a fallback to unencrypted DNS is visible without
opening the app.

## Today

- `StatusProvider.makeEntry` reads `stats.json`, `SharedSettings.protectionActive`
  and `pausedUntil`. It shows "Protected", "Paused" or "Off" plus blocked
  counts.
- The resolver state (`ResolverStatus`: `.network`, `.alternative(name,
  encrypted)`, `.fallingBack(name)`, `.failing(name)`) lives only in the
  tunnel process (`router.status`). The app gets it over IPC (`getStats`).
  Widgets can't use IPC, so they have no way to read it.
- `ResolverStatusPresentation` (`IBlockerKit/Shared`) builds the Dashboard
  wording.
- The tunnel already sees every status change through
  `ResolverRouter.onStatusChange`, which is used for notifications.

## Changes

### 1. Tunnel publishes the resolver status

- Add `SharedSettings.widgetResolverStatus: ResolverStatus?`. It's stored as
  JSON in the App Group defaults and is nil when missing or undecodable.
- The tunnel writes it in these places:
  - **Start:** next to `settings?.protectionActive = true`, after
    `setTunnelNetworkSettings` succeeds, not when the router is created.
    During a degraded start (settings still unreadable before first unlock)
    it writes **nil**, so the line stays hidden instead of showing a
    misleading "Unencrypted DNS" from the default router.
  - **Status changes:** on every resolver status change, through the existing
    `onStatusChange` path. The router-generation check runs before both the
    write and the reload decision.
  - **New routers:** after `setUpstream` from IPC (`.setResolverSettings`) and
    from the recovery `reapplySettings` branch. A new router doesn't fire
    `onStatusChange` for its first status, so these paths call the shared
    publish helper directly.
- `stopTunnel` clears the value (sets nil).
- **Reload from the tunnel (required).** The tunnel calls
  `WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.statusWidget)`
  itself, since the point of the feature is to see a fallback without opening
  the app. `WidgetCenter` is allowed in app extensions.
  - Add `- sdk: WidgetKit.framework` to the PacketTunnel target's
    dependencies in `ios/project.yml`, then regenerate with XcodeGen.
  - It reloads unconditionally once at start and once in `stopTunnel`, so the
    widget shows Protected or Off promptly even for system, on-demand and
    Control Center starts and stops.
  - Between start and stop, it reloads **only when the displayed state
    changes**: the `WidgetEncryptionPresentation.state` below, or the
    resolver name. This keeps reloads within WidgetKit's daily budget even if
    the resolver flaps.
- **Reload decision:** a pure struct `WidgetReloadGate` in IBlockerKit. It
  takes the last published `(state, name)?` and the new `ResolverStatus?`,
  and returns `shouldReload` plus the new value to remember.
  - The provider keeps it in a `LockedBox`, shared by all write paths
    (callback threads and the provider actor).
  - It's reset to nil in `stopTunnel`.
  - Ordering: the write and the decision happen inside one `LockedBox`
    critical section, so a late callback can't overwrite a newer
    `setUpstream` value. The generation check rejects stale routers.
- **Stale state (known limitation):** if the tunnel dies without
  `stopTunnel` (jetsam or a crash), the stored status and `protectionActive`
  both stay set until the next start or app launch. The widget trusts
  `protectionActive`, as it does today. To narrow the window,
  `TunnelController` clears `widgetResolverStatus` and calls
  `VPNControl.reloadWidgets()` when it sees the VPN `disconnected` or
  `invalid` while the stored value is non-nil.

### 2. Presentation (pure, testable)

Add `WidgetEncryptionPresentation` in `IBlockerKit/Shared`. Inputs:
`protectionActive`, `paused`, `ResolverStatus?`. `paused` means
`(pausedUntil ?? .distantPast) > now`, matching `TunnelController.isPaused`.
`makeEntry` uses the same definition for the existing "Paused" header,
which fixes an expired deadline reading as paused. Output: `state`, `symbol`,
`text` and `tone`.

| Input | state | symbol | text | tone |
|---|---|---|---|---|
| off or paused | hidden | — | — | — |
| `.alternative(name, true)` | encrypted | `lock.fill` | "Encrypted · \(name)" | positive |
| `.network` | unencrypted | `lock.open.fill` | "Unencrypted DNS" | warning |
| `.alternative(name, false)` | unencrypted | `lock.open.fill` | "Unencrypted · \(name)" | warning |
| `.fallingBack(name)` | fallback | `exclamationmark.triangle.fill` | "Encrypted DNS unavailable" | warning |
| `.failing(name)` | failing | `xmark.octagon.fill` | "DNS failing" | critical |
| active, status nil | unknown | — | — | — (line hidden) |

Tones map to the widget colours: positive green, warning orange, critical
red.

### 3. Widget layout

- **systemSmall / systemMedium:** add one line under the status header with
  the symbol and text, in `.caption2`, coloured by tone. Hide it in the
  hidden and unknown states. The blocked counts stay. Long resolver names
  truncate at the tail, on one line.
- **accessoryRectangular:** add a third line with the symbol and text, using
  the system's monochrome styling (no colour on the Lock Screen).
- **accessoryInline, accessoryCircular:** unchanged.
- The widget placeholder shows the encrypted state with a sample name
  ("Cloudflare").
- `StatusEntry` gains the presentation, or its inputs.

## Logging

Follow `docs/LOGGING.md`.

- `tunnel`, **info**: `widget resolver status: <state> (<name>)` when the
  displayed state changes and a reload is requested.
- `tunnel`, **debug**: `widget resolver status unchanged (<state>), no reload`.
- `tunnel`, **error**: failure to encode or write the status.
- Widget extension, category `widgets` (new; add it to `docs/LOGGING.md`),
  **debug**: `status entry: active=<b> paused=<b> encryption=<state>` in
  `makeEntry`. The Widgets extension uses `os.Logger` directly, like the
  `controls` category in `ios/Widgets/PauseControls.swift`. Follow the same
  pattern.
- `tunnel`, **debug**: `widget reload requested (start|stop|change)`.
- `ui`, **info**: `cleared stale widget resolver status (vpn <status>)`.

## Acceptance Criteria

1. `WidgetEncryptionPresentation` returns the table above for every input,
   including off, paused and unknown. Unit tests.
2. `SharedSettings.widgetResolverStatus` round-trips every `ResolverStatus`
   case and returns nil for missing or garbage data. Unit tests.
3. The tunnel requests a widget reload only when the displayed state or the
   resolver name changes. Unit-test the decision as a small pure helper; the
   provider calls it.
4. On device, with an encrypted resolver, the small widget shows
   "Encrypted · <name>" under "Protected".
5. On device, with fallback enabled and the alternative resolver blocked,
   the small widget shows "Encrypted DNS unavailable" within 60 s of the
   tunnel's fallingBack status change, with the app not running. Console
   shows the `widget resolver status: fallback` info line.
6. With protection off or paused, the encryption line is hidden.
7. After a stop from Control Center or the system, the widget shows Off with
   no encryption line, without opening the app.
7a. A degraded start (settings unreadable) publishes nil. `WidgetReloadGate`
   unit tests cover: no reload for the same state and name; a reload for a
   new state or name; reset after stop.
7b. Memory: the `available memory` figure in the tunnel's `tunnel up` log is
   within about 1 MB of the build before this change.
8. The Logging lines appear at their levels. Unit tests where practical, and
   Console.app on device.

## Scope

**In:** the shared status value, the tunnel writes and reload requests, the
presentation type, the status widget layout, and the docs (`docs/LOGGING.md`
category, `docs/ARCHITECTURE.md` widget data flow).

**Out:** the Control Center controls (`ProtectionControl`, pause buttons),
interactive widgets, new widget kinds, and notification changes.

## Files to Add/Modify (hints)

| File | Change |
|---|---|
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/SharedSettings.swift` | `widgetResolverStatus` |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/WidgetEncryptionPresentation.swift` | new |
| `ios/PacketTunnel/PacketTunnelProvider.swift` | publish helper, write, clear, reloads |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/WidgetReloadGate.swift` | new, pure reload decision |
| `ios/project.yml` | link WidgetKit into PacketTunnel |
| `ios/IBlockerKit/Sources/IBlockerUI/System/TunnelController.swift` | clear stale status on disconnect |
| `ios/Widgets/StatusWidget.swift` | entry and layout |
| `ios/IBlockerKit/Tests/IBlockerKitTests/…` | presentation, persistence and reload-decision tests |
| `docs/LOGGING.md`, `docs/ARCHITECTURE.md` | widgets category, data flow |
