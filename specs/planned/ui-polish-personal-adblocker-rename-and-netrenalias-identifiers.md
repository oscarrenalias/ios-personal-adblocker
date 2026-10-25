---
name: "UI polish, Personal AdBlocker rename and net.renalias identifiers"
id: spec-54a5b4a5
description: "Remove Verify from Dashboard, rename to Personal AdBlocker, move identifiers to net.renalias, black background, non-ticking list age"
dependencies: null
priority: medium
complexity: null
status: planned
tags:
- ui
- branding
scope:
  in: null
  out: null
feature_root_id: B-8e60a908
---
# UI polish, Personal AdBlocker rename and net.renalias identifiers

## Objective

Five small polish items requested by the user on 2026-10-25:
- remove "Verify ad blocking" from the Dashboard
- rename the app to **Personal AdBlocker** everywhere it shows
- move all reverse-DNS identifiers to the **`net.renalias`** namespace
- a true black background in dark mode
- an "updated … ago" label in Filter Lists that doesn't tick every second

## Problems to Fix

1. `DashboardView` (`ios/IBlockerKit/Sources/IBlockerUI/Dashboard/DashboardView.swift`,
   around line 30) shows a "Verify ad blocking" button. Settings already has
   "Verify blocking (in-app ad test)", which is the only place it should be.
2. The app still uses the upstream names "Just an AdBlocker" and
   "AdBlocker":
   - Info.plist display names: `ios/App`, `ios/PacketTunnel`,
     `ios/ContentBlocker`, `ios/Widgets`
   - the Dashboard navigation title
   - the VPN configuration name shown in iOS Settings
     (`TunnelController`, `localizedDescription = "AdBlocker"`)
   - `TunnelConstants.serverDescription`
   - widget and Control Center names
   - App Intent descriptions
   - `VPNControl` error text
   - onboarding copy
   - the Settings "About" text
   - `MobileConfigBuilder` and `ProfileExportView` profile names and file
     names
3. Identifiers use other namespaces:
   - bundle IDs and the App Group come from `BUNDLE_ID_PREFIX = com.renalias`
     in `ios/project.yml` (`com.renalias.iblocker`, `.tunnel`, `.blocker`,
     `.widgets`, `group.com.renalias.iblocker`)
   - log subsystem `com.iblocker` (`Log.swift`)
   - a leftover `com.iblocker.tunnel.path` logger in `PacketTunnelProvider`
   - widget kinds `com.iblocker.widget.status` and
     `com.iblocker.control.protection` (`WidgetKinds.swift`)
   - the placeholder `group.invalid.iblocker` in `AppEnvironment.swift`
4. In dark mode the background is a dark purple: `DashboardBackground`
   (`DashboardView.swift`, around line 244) is a blue → purple gradient. It's
   used on the Dashboard and in Onboarding.
5. `FilterListsView` (`ios/IBlockerKit/Sources/IBlockerUI/Lists/FilterListsView.swift`,
   around line 102) uses `Text("updated \(fetched, style: .relative) ago")`,
   which SwiftUI updates every second ("1 min, 47 secs").

## Changes

### 1. Verify button

Remove the "Verify ad blocking" button from `DashboardView`. Keep the
Settings entry exactly as it is.

### 2. Rename to "Personal AdBlocker"

Every user-visible app name becomes **"Personal AdBlocker"**:

| Where | New text |
|---|---|
| App display name (`ios/App/Info.plist` `CFBundleDisplayName`) | Personal AdBlocker |
| Tunnel extension display name | Personal AdBlocker Tunnel |
| Safari blocker display name | Personal AdBlocker Safari Blocker |
| Widgets display name | Personal AdBlocker Widgets |
| Dashboard navigation title | Personal AdBlocker |
| VPN configuration name in iOS Settings (`TunnelController`) | Personal AdBlocker |
| `TunnelConstants.serverDescription` | Personal AdBlocker (on-device) |
| Widget, Control Center, App Intents, `VPNControl`, onboarding, Settings "About" | replace "AdBlocker" / "Just an AdBlocker" with "Personal AdBlocker" |
| `.mobileconfig` profile display name and exported file name | "Personal AdBlocker", file `PersonalAdBlocker-<preset>.mobileconfig` |

- When the app saves an existing VPN configuration whose name differs, it
  updates the name, so iOS Settings shows the new one.
- The Swift module, target and scheme names (`IBlockerKit`, `IBlockerUI`,
  `IBlockerTunnelKit`, the `IBlocker` target and scheme) stay the same. See
  Pending Decisions.

### 3. `net.renalias` identifiers

| Identifier | New value |
|---|---|
| `BUNDLE_ID_PREFIX` (`ios/project.yml`) | `net.renalias` |
| App bundle ID | `$(BUNDLE_ID_PREFIX).adblocker` → `net.renalias.adblocker` |
| Extension bundle IDs | `net.renalias.adblocker.tunnel`, `.blocker`, `.widgets` |
| App Group (`APP_GROUP_ID`) | `group.net.renalias.adblocker` |
| Log subsystem (`Log.swift`) | `net.renalias.adblocker` |
| Path logger | uses the `Log` wrapper, category `path` (no separate subsystem) |
| Widget kinds (`WidgetKinds.swift`) | `net.renalias.adblocker.widget.status`, `net.renalias.adblocker.control.protection` |
| `AppEnvironment` placeholder group | `group.invalid.adblocker` |

- Derived identifiers, such as the background-task ID
  (`<bundle id>.refresh`), follow automatically. Make sure nothing still
  hardcodes `iblocker`.
- **Not migrated:** a new bundle ID is a new app on the device. The old app,
  its VPN configuration and its App Group data (downloaded lists, settings,
  log) stay with the old app. That's acceptable for this personal app (see
  the on-device steps). Don't write migration code.

### 4. Black background

- Replace the gradient in `DashboardBackground` with the system background:
  `Color(.systemBackground)`, which is pure black in dark mode and white in
  light mode. Keep the type name, since the Dashboard and Onboarding use it.
- Don't change the other tabs (Lists, Log, Settings). They use system list
  backgrounds, which are already black in dark mode.

### 5. "Updated … ago" without a ticking timer

- Add a pure formatter in `IBlockerKit`,
  `ListAgeText.updated(since: Date, now: Date) -> String`:
  - less than 60 s → **"updated just now"**
  - less than 60 min → **"updated N min ago"**
  - less than 24 h → **"updated N h ago"**
  - otherwise → **"updated N days ago"** ("1 day")

  No seconds, and round down.
- `FilterListsView` uses it with the current time when the view renders.
  It doesn't update itself every second. It's fine for the text to refresh
  only when the view re-renders: on appear, after an update, or on pull to
  refresh.

### 6. Docs

- `docs/LOGGING.md`: the subsystem becomes `net.renalias.adblocker`
  everywhere, including the Console and `log show` filter examples.
- `docs/SIGNING.md` and `README.md`: the new prefix, bundle IDs, App Group
  and app name.
- Grep `docs/` for `com.iblocker` and `com.renalias` and update them all.

## Files to Modify

| File | Change |
|---|---|
| `ios/IBlockerKit/Sources/IBlockerUI/Dashboard/DashboardView.swift` | Items 1, 2 (title), 4 |
| `ios/App/Info.plist`, `ios/PacketTunnel/Info.plist`, `ios/ContentBlocker/Info.plist`, `ios/Widgets/Info.plist` | Item 2 |
| `ios/IBlockerKit/Sources/IBlockerUI/**` (TunnelController, VPNControl, IBlockerIntents, Onboarding, SettingsView, ProfileExportView), `ios/Widgets/*.swift`, `ios/IBlockerKit/Sources/IBlockerKit/{Shared/TunnelConstants.swift,Profile/MobileConfigBuilder.swift}` | Item 2 |
| `ios/project.yml`, `ios/IBlockerKit/Sources/IBlockerKit/Shared/{Log.swift,WidgetKinds.swift}`, `ios/IBlockerKit/Sources/IBlockerUI/AppEnvironment.swift`, `ios/PacketTunnel/PacketTunnelProvider.swift` | Item 3 |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/ListAgeText.swift` (new), `ios/IBlockerKit/Sources/IBlockerUI/Lists/FilterListsView.swift` | Item 5 |
| `ios/IBlockerKit/Tests/IBlockerKitTests/` | Tests |
| `docs/LOGGING.md`, `docs/SIGNING.md`, `README.md` | Item 6 |

## Logging

Follow [docs/LOGGING.md](../../docs/LOGGING.md). There are no new events.
Every existing logger moves to subsystem `net.renalias.adblocker` through the
`Log` wrapper, including the path logger, which currently creates its own
`Logger(subsystem: "com.iblocker.tunnel", …)`.

## Acceptance Criteria

Automated:

1. `ListAgeText.updated` returns:
   - "updated just now" for 0 s and 59 s
   - "updated 1 min ago" for 60 s and 119 s
   - "updated 59 min ago" for 3599 s
   - "updated 1 h ago" for 3600 s
   - "updated 23 h ago" for 86399 s
   - "updated 1 day ago" for 86400 s
   - "updated 3 days ago" for 3 days
2. `Log.subsystem == "net.renalias.adblocker"`, and the widget kind
   constants have their new values.
3. All existing tests pass, and IBlockerKit builds on Linux.

Code review (grep from the repo root, excluding `.git`, `.takt` and
`specs/done`):

4. No occurrences of `com.iblocker`, `com.renalias`, `Just an AdBlocker`
   or `iblocker` in identifiers, under `ios/` or `docs/`. Swift module and
   type names containing `IBlocker` are allowed.
5. No user-visible string says "AdBlocker" except as part of "Personal
   AdBlocker".
6. `DashboardView` has no "Verify ad blocking" button, and SettingsView
   still has "Verify blocking (in-app ad test)".
7. `FilterListsView` no longer uses `style: .relative`.

Build:

8. `cd ios && xcodegen generate && xcodebuild build -project IBlocker.xcodeproj -scheme IBlocker -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`
   succeeds.

On device (manual, by the user):

9. **Delete the old "Just an AdBlocker" app first.** That also removes its
   VPN configuration. Then install. The home screen shows **Personal
   AdBlocker**, and iOS Settings ▸ VPN shows **Personal AdBlocker**.
10. The app needs a fresh setup: onboarding, list download, enabling
    protection.
11. Dark mode: the Dashboard and Onboarding backgrounds are pure black.
12. The Dashboard has no Verify button, and Settings does.
13. Filter Lists shows "updated just now" right after an update and "updated
    N min ago" later. Nothing ticks every second.
14. Widgets need re-adding (new widget kinds). The Control Center toggle
    works after it's re-added.
15. A log stream filtered on `subsystem:net.renalias.adblocker` shows
    messages.

## Scope

**In scope:** items 1–6.

**Out of scope:**
- Renaming Swift modules, targets, schemes or type names (`IBlocker*`).
- Migrating data from the old bundle ID or App Group.
- Changing the accent colour or the tile tints.

## Pending Decisions

- **Swift module and type names** (`IBlockerKit`, the `IBlocker` target and
  so on) are left as they are. Renaming them is a large mechanical refactor
  across every file and every test. The user can ask for it as a separate
  spec if wanted.
- **Bundle ID suffix:** `adblocker` (`net.renalias.adblocker`). Change it
  here before planning if a different suffix is preferred.
