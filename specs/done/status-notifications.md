---
name: Status notifications
id: spec-8d9a86ec
description: "Local notifications for resolver fallback/failure, unexpected protection stop, built-in-rules-only, list rejections/staleness, pause ended, and restores; debounced, opt-in, no domains"
dependencies: null
priority: medium
complexity: null
status: done
tags:
- notifications
- tunnel
- ui
scope:
  in: null
  out: null
feature_root_id: B-3c33475a
---
# Status notifications

## Objective

The user gets a local notification when protection changes while they're not
looking at the app: encrypted DNS lost, lookups failing, protection stopped,
only built-in rules active, a blocklist problem, or a pause ending. They get a
matching "back to normal" notification when a notified problem clears.

This is `docs/ROADMAP.md` item 7 (Status notifications). The scenario list was
agreed with the user on 2026-10-26 and is restated below.

## Events

| # | Event | Raised by | Example text |
|---|---|---|---|
| 1 | Alternative resolver unreachable, falling back to network DNS (`ResolverStatus.fallingBack`) | tunnel | "Encrypted DNS unavailable. Lookups are going unencrypted to your network's DNS." |
| 2 | Alternative resolver unreachable with fallback off (`ResolverStatus.failing`) | tunnel | "DNS lookups are failing. <resolver name> can't be reached and fallback is off." |
| 3 | Protection stopped, not by the user | tunnel (and app, see below) | "Ad blocking is off. Another VPN may have taken over, or protection stopped. Open the app to turn it back on." |
| 4 | Restored: any of 1, 2, 3 or 7 clears **after its notification was shown** | tunnel | "Encrypted DNS restored (<name>)." / "Ad blocking is back on." / "All blocklists are active again." |
| 5 | A blocklist update was rejected, or a list became stale (more than 7 days, `ListFreshness`) | app | "Blocklist update rejected: <list name>. Using the previous version." / "<list name> hasn't updated in over 7 days." |
| 6 | A pause ended on its own and protection resumed | tunnel | "Pause ended. Ad blocking is back on." |
| 7 | Only built-in rules active (tunnel degraded, `TunnelRecovery.isDegraded`) for more than 5 minutes | tunnel | "Only built-in rules are active. Your blocklists couldn't be loaded yet." |

Exact wording may be adjusted. The content rules below can't be.

## Behaviour

### Debounce and "notify once"

Short-lived problems must not produce notifications, so network switches,
captive portals and on-demand restarts stay quiet:

- A problem notification (1, 2, 3, 7) only appears if the problem lasts:
  - 30 s for 1 and 2
  - 60 s for 3
  - 5 min for 7

  If it clears sooner, nothing is shown.
- **Suggested mechanism**, which also covers the tunnel exiting or being
  suspended: when the problem starts, schedule the notification with a
  `UNTimeIntervalNotificationTrigger` of that delay. When the problem clears,
  remove the still-pending request.
  - For 3, this means `stopTunnel` schedules a 60 s notification and the next
    `startTunnel` cancels it. So an on-demand restart within 60 s posts
    nothing.
- **One notification per problem episode.** While a problem continues, or
  repeats with the same kind, don't post again until it has been restored.
- **Event 3 episode:**
  - It starts at an unexpected stop.
  - Further unexpected stops while it's open don't schedule again.
  - It ends at the first `startTunnel` after the notification was delivered.
    That start posts the restore.
  - If the start comes before delivery, the pending request is removed and
    the episode ends silently.
  - A flapping VPN (off, on, off, on) can therefore produce several
    stopped/restored pairs. Only the rate limit bounds them. This is accepted.
- **"Delivered" means** the scheduled fire time has passed and the request
  wasn't removed. Each episode records its scheduled fire time in
  `SharedSettings`, so delivery is computed from the clock and doesn't query
  `getDeliveredNotifications`. Clearing the notification from Notification
  Center doesn't change this.
- **Rate limit:** at most one notification per event kind per 5 minutes,
  restored notifications included.
  - It's evaluated **when scheduling**, against the projected fire time and
    the fire times already recorded for that kind.
  - A request that would break the limit isn't scheduled. Its episode is
    still opened, so no restore follows.
  - Episode state and fire times live in the App Group (`SharedSettings`), so
    they survive tunnel restarts.
- **Restored (4)** is posted only if the problem's notification was
  delivered. Pending-but-cancelled doesn't count. It reuses the problem's
  notification identifier, so it replaces the problem notification in
  Notification Center instead of stacking under it.
- **Changing kinds:** a switch from 1 to 2 (or 2 to 1) is a new problem, not
  a restore.
  - The old kind's pending request is removed and its episode ends with no
    restore.
  - The new kind starts its own 30 s debounce.
- **Tunnel stops:** every `stopTunnel` (user-initiated or not) removes
  pending 1, 2, 6 and 7 requests and ends their episodes with no restore.
  The tunnel isn't running, so those states no longer apply. Event 3 covers
  an unexpected stop.
  - If the tunnel dies without `stopTunnel`, an already-scheduled 6 or 7 may
    still fire. This is accepted.
  - The app's "tunnel gone" check (below) also removes them when it detects
    that case.
- **Pause ended (6):** posted when a pause expires on its deadline. It is
  *not* posted when:
  - the user resumes early (app, widget, Control Center or Shortcut)
  - the user turns protection off
  - the tunnel isn't running at the deadline

  Suggested mechanism: schedule the notification for `pausedUntil` whenever
  the tunnel sees a new future deadline (it already re-reads it every 2 s),
  and remove it when the pause is cleared or shortened.
- **Lists (5):** posted from the app's update pipeline (`FilterListStore`),
  once per list per episode:
  - A rejection episode ends when an update for that list is accepted.
  - A stale episode ends when the list is accepted again.
  - Rejections from an update the user started in the Lists screen are shown
    there already, so they aren't notified (trigger `.user`).
  - Rejections from `background`, `shortcut` and `stale-check` triggers are
    notified.
  - Staleness is evaluated after every update run, including the background
    refresh in `ListRefreshScheduler.handle`, not only in the foreground.
    Otherwise a stale list would only be noticed while the app is open.

### "Stopped, not by the user" (3)

- "Not by the user" means the stop wasn't requested by:
  - this app's toggle
  - a widget, Control Center or Shortcut
  - the user turning the VPN off in iOS Settings
- Detection:
  - Every off path records a "user turned protection off" marker
    (`SharedSettings.userTurnedOff`) before calling `stopVPNTunnel`. The off
    paths are:
    - `TunnelController`
    - `VPNControl`
    - the intents in `IBlockerIntents.swift`
    - the Control Center control (`ControlProtectionIntent` in
      `ios/Widgets/ProtectionControl.swift`, which calls `stopVPNTunnel`
      itself)
  - The marker is **separate from** `SharedSettings.protectionActive`.
    - `protectionActive` mirrors tunnel state for widgets, and the tunnel
      sets it to false on every stop.
    - The marker records the user's *intent*, and only on/off actions change
      it.
    - Don't reuse `protectionActive` for this.
  - In `stopTunnel`, the reason is classified as user-initiated if:
    - the marker is set, or
    - the reason is `.userInitiated` (which covers the iOS Settings toggle).
  - The reason `.appUpdate` is also not notified.
  - Every other reason is unexpected. This includes `.superceded`, which is
    expected when another VPN app connects, and provider failures.
  - Turning protection on clears the marker.
- **Tunnel gone with no `stopTunnel`** (crash or jetsam, and on-demand didn't
  bring it back): when the app's background refresh runs, it checks:
  - the user has protection turned on (marker not set)
  - the VPN connection is not connected and not connecting
  - event 3 hasn't already been notified for this outage

  If all hold, the app posts event 3 and removes any pending 6 or 7. This is
  best effort, since background refresh timing is up to iOS.
- The app also posts "Ad blocking is back on" (4) for this case when it next
  sees the tunnel connected. In all other cases the tunnel posts it from
  `startTunnel`.

### Who posts

- The tunnel extension posts events 1, 2, 3, 4, 6 and 7 directly through
  `UNUserNotificationCenter`. The app posts 5, plus the fallback cases of 3
  and 4 above.
- Whether a packet tunnel extension may post local notifications must be
  confirmed on device; this can't be checked in CI. The spec relies on it.
  - If `add(_:)` fails in the extension, the error is logged (see Logging).
  - The device check is a manual acceptance step.
  - If it fails on device, a follow-up spec will move posting to the app.
    That's out of scope here.

### User control

- **Settings ▸ Notifications** section:
  - a master switch, **off by default**
  - per-type toggles, all on by default, shown only when the master switch
    is on:
    - **Encrypted DNS** (events 1, 2 and their restores)
    - **Protection stopped** (events 3, 7 and their restores)
    - **Pause ended** (event 6)
    - **Blocklists** (event 5)
- Turning the master switch on requests notification authorization
  (`.alert`, `.sound`).
  - If the user denies it, or it was denied before, the switch goes back to
    off.
  - The section then shows "Notifications are turned off for Personal
    AdBlocker in iOS Settings" with a button that opens the app's iOS
    Settings page.
- The app never asks for permission at launch or during onboarding.
- Preferences are stored in `SharedSettings` (App Group) so the tunnel can
  read them. Every poster checks the master switch and the type toggle
  before scheduling.
- Turning a type, or the master switch, off removes that type's pending
  requests.

### Content and privacy

- Never include a domain name, IP address, URL or query.
- **Resolver:** show the preset's name for presets, and "your custom
  resolver" for a custom one. Never show the DoH URL or its host, and never
  show a user-typed custom resolver name.
- **List:** show a built-in list's name, or the name the user entered for a
  custom list. If a custom list has no name, show "a custom blocklist". Don't
  use the `url.host()` fallback that `FilterListsView` uses for display.
- **Tapping a notification** opens the app on the right tab:
  - Dashboard for events 1, 2, 3, 4, 6 and 7
  - Lists for event 5

  This works through the notification's `userInfo`, routed by a
  `UNUserNotificationCenterDelegate` in the app that switches `RootView`'s
  selected tab.
- While the app is in the foreground, notifications are shown as banners
  (the delegate's `willPresent` returns `.banner`, `.list`).

## Acceptance Criteria

1. A pure, unit-tested policy type in IBlockerKit decides, for each event and
   point in time, whether to schedule, cancel, post a restore, or do nothing.
   It covers the debounce, once-per-episode, 5-minute rate limit,
   restore-only-if-delivered and kind-change (1 to 2) rules. Tests use an
   injected clock, with no real `UNUserNotificationCenter`.
2. Stop-reason classification is a pure function with unit tests:
   - `.userInitiated`, `.appUpdate`, or the user-off marker set → not
     notified
   - `.superceded`, `.providerFailed` and other reasons with no marker →
     notified
3. Notification preferences (master plus four types) and the
   user-turned-off marker round-trip through `SharedSettings`. They have the
   documented defaults (master off, types on, marker unset) and unit tests.
4. Notification content builders are unit-tested to never contain a domain
   name, IP address or URL. Tests must cover:
   - a custom resolver whose DoH URL contains a hostname, shown as "your
     custom resolver"
   - an IP-literal preset, shown by its preset name and not the IP
   - a custom list with an empty name and a URL with a host, shown as "a
     custom blocklist"

   The builders also set the correct tab in `userInfo`.
5. In the tunnel:
   - resolver status changes to and from `fallingBack` or `failing` drive
     events 1, 2 and 4. `ResolverRouter` exposes a status-change callback,
     invoked from `noteStatusChange()` outside the lock, instead of the
     tunnel polling.
   - `stopTunnel` and `startTunnel` drive events 3 and 4
   - degraded start and recovery drive events 7 and 4
   - pause deadline changes drive event 6

   - every `stopTunnel` removes pending 1, 2, 6 and 7 and ends their
     episodes without a restore

   All of these go through the policy type and respect the preferences.
6. `FilterListStore` update results and stale checks drive event 5 according
   to the trigger rules above. The background refresh also runs the stale
   evaluation.
7. The Settings ▸ Notifications section behaves as described:
   - permission is requested only when the master switch is turned on
   - after a denial the switch reverts and the "turned off in iOS Settings"
     row with its open-Settings button is shown
   - turning toggles off removes pending requests
8. Tapping a notification opens the Dashboard or Lists tab as specified.
9. Every off path listed above sets `userTurnedOff` before stopping,
   including `ControlProtectionIntent`. Every on path clears it.
10. `swift test --package-path ios/IBlockerKit` passes, and the iOS app
    builds (CI).
11. The events in the Logging section are logged at the stated levels, with
    no domain names.
12. **Manual (on device, by the user):**
    - The extension can post.
    - Switching a cloud VPN app on produces exactly one "Ad blocking is off"
      notification about 60 s later.
    - Switching back produces "Ad blocking is back on".
    - A 5-minute pause that runs out produces "Pause ended".
    - Choosing an unreachable alternative resolver produces the "Encrypted
      DNS unavailable" notification after about 30 s.

## Logging

Per [docs/LOGGING.md](../../docs/LOGGING.md), subsystem
`net.renalias.adblocker`, new category `notify`. Use the same category in the
tunnel and the app. Never log domain names in this category.

| Event | Level | Example |
|---|---|---|
| Notification scheduled (kind, delay) | notice | `scheduled resolver-fallback in 30 s` |
| Pending notification cancelled because the problem cleared in time | info | `cancelled pending protection-stopped (cleared after 12 s)` |
| Restore posted | notice | `posted restored for resolver-fallback` |
| Suppressed (master off, type off, not authorized, rate-limited, already notified this episode) | info | `suppressed pause-ended: type disabled` |
| `UNUserNotificationCenter.add` / authorization query failed | error | `add failed for protection-stopped: <error>` |
| Stop reason classification | notice | `stop reason superceded, user-off marker no -> unexpected` |
| Authorization requested and result | notice | `authorization requested: granted` / `denied` |
| Preference changed | info | `notifications master on, types dns,stopped,pause,lists` |
| Tap routed | info | `opened from notification kind list-rejected -> lists` |
| Background-refresh "tunnel gone" check result | info | `tunnel check: user wants on, status disconnected -> notify` |
| Policy decision detail (inputs and outcome) | debug | |

## Scope

**In:**
- events 1–7 as described
- Settings ▸ Notifications
- the user-off marker
- tap routing
- the background-refresh fallback for event 3
- unit tests
- a new "Notifications" subsection in `docs/ARCHITECTURE.md`

**Out:**
- moving posting to the app if the extension can't post (follow-up spec)
- the protection health indicator (ROADMAP item 5)
- notifications for anything not listed
- notification actions (buttons)
- remote or push notifications
- changing the existing Dashboard status line

## Files to Add/Modify (hints)

- **New:** `ios/IBlockerKit/Sources/IBlockerKit/Shared/StatusNotificationPolicy.swift`
  (policy, kinds, stop-reason classification, content builders; pure, no
  UserNotifications import if practical)
- **New:** a thin poster wrapping `UNUserNotificationCenter`, in a place
  usable by both the tunnel and the app. For example, in
  `ios/IBlockerKit/Sources/IBlockerKit/Shared/`. The package is iOS-only,
  so don't add platform guards.
- `ios/IBlockerKit/Sources/IBlockerKit/Shared/SharedSettings.swift`:
  preferences, episode state, user-off marker.
- `ios/PacketTunnel/PacketTunnelProvider.swift`: hooks in `startTunnel`,
  `stopTunnel` and the maintenance loop. Get resolver status changes from
  `ResolverRouter`
  (`ios/IBlockerKit/Sources/IBlockerKit/Engine/ResolverRouter.swift`,
  `noteStatusChange`), via a new status-change callback.
- `ios/IBlockerKit/Sources/IBlockerKit/Lists/FilterListStore.swift`: event 5.
- **Off paths** that need the marker:
  - `ios/IBlockerKit/Sources/IBlockerUI/System/TunnelController.swift`
  - `ios/IBlockerKit/Sources/IBlockerUI/System/VPNControl.swift`
  - `ios/IBlockerKit/Sources/IBlockerUI/System/IBlockerIntents.swift`
  - `ios/Widgets/ProtectionControl.swift`
- `ios/IBlockerKit/Sources/IBlockerUI/System/ListRefreshScheduler.swift`:
  the "tunnel gone" check.
- `ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift` plus a new
  `NotificationSettingsView.swift`.
- `ios/IBlockerKit/Sources/IBlockerUI/RootView.swift`: tab routing from
  taps.
- `ios/App/IBlockerApp.swift`: notification center delegate.
