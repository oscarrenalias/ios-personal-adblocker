---
name: Encryption status in the Dashboard status line
id: spec-d10b070a
description: Show encryption/fallback state in the existing Dashboard status line and Settings DNS section; depends on spec-c7e3c45d
dependencies: null
priority: high
complexity: null
status: done
tags:
- dns
- ui
- privacy
scope:
  in: null
  out: null
feature_root_id: B-a13ff8ff
---
# Encryption status in the Dashboard status line

## Objective

Make it clear and obvious in the app when DNS lookups are going out
unencrypted, including when a fallback causes it. Show this in the existing
Dashboard status line and at the top of the DNS settings.

**Depends on:** `spec-c7e3c45d` ("Alternative resolver with failover to
network DNS") being merged. It provides `ResolverStatus` and
`TunnelRuntimeStats.resolverStatus`.

## Problems to Fix

- The Dashboard status line (`DashboardView.statusLine`,
  `ios/IBlockerKit/Sources/IBlockerUI/Dashboard/DashboardView.swift`) says
  "Protected — DNS filtering active" whether lookups are encrypted or not,
  and whether or not a fallback is in effect.
- The user asked (2026-10-25) that unencrypted lookups be clear and obvious,
  in that existing status line, not in a new row or banner.

## Changes

### 1. ResolverStatusPresentation (pure logic, IBlockerKit)

A pure mapping from `(tunnelConnected: Bool, resolverStatus: ResolverStatus?)`
to what the status line shows:

- **Icon:** an SF Symbol name (`String`).
- **Tone:** a semantic enum `.positive | .warning | .critical | .neutral`.
  IBlockerKit must build on Linux without SwiftUI, so the UI maps the tone to
  `Color` (green, orange, red, secondary).
- **Main line** and an optional **caption**.
- **`showsDNSSettingsButton: Bool`.**

Put it in `ios/IBlockerKit/Sources/IBlockerKit/Shared/`, following the
existing `RulesTilePresentation`.

### 2. Dashboard status line

While `tunnel.state == .connected`, `statusLine` uses the presentation:

| `resolverStatus` | Icon | Tone | Main line | Caption |
|---|---|---|---|---|
| `alternative(name, encrypted: true)` | `checkmark.shield.fill` | positive | **"Protected — encrypted DNS (<name>)"** | — |
| `network` | `lock.open.fill` | warning | **"Protected — unencrypted DNS (Network DNS)"** | **"Your network can see the sites you look up."** |
| `alternative(name, encrypted: false)` | `lock.open.fill` | warning | **"Protected — unencrypted DNS (<name>)"** | **"<name> and your network can see the sites you look up."** |
| `fallingBack(name)` | `exclamationmark.triangle.fill` | warning | **"Protected — encrypted DNS unavailable"** | **"<name> can't be reached. Lookups are going unencrypted to your network's DNS until it's back."** + **"DNS settings"** button |
| `failing(name)` | `xmark.octagon.fill` | critical | **"DNS lookups are failing"** | **"<name> can't be reached and fallback is off."** + **"DNS settings"** button |
| `nil` (no stats yet, or the tunnel doesn't report it) | `checkmark.shield.fill` | positive | **"Protected — DNS filtering active"** (today's text) | — |

- Other tunnel states (connecting, disconnected, not installed, permission
  needed, unknown) keep today's text and icon unchanged.
- The caption is a smaller line directly under the main line, in the same
  status line area. Don't add a separate row or banner.
- The pause UI stays where it is.
- The Dashboard's existing 3 s `refreshLoop` already fetches stats, so no new
  polling is needed.

### 3. "DNS settings" button

- `RootView`'s `TabView`
  (`ios/IBlockerKit/Sources/IBlockerUI/RootView.swift`) gets a `selection`
  binding with a tag per tab.
- The button switches to the **Settings** tab. Scrolling to the section is
  not required.

### 4. Settings: status at the top of the DNS section

- At the top of the "Upstream DNS (VPN mode)" section in `SettingsView`
  (`ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift`), show
  the presentation's icon and main line, tinted by tone. No caption, no
  button.
- Data source: fetch through `TunnelController.refreshStats()` when the view
  appears, and every 3 s while it's visible (a `.task` loop, like the
  Dashboard). Show nothing when stats aren't available.

### 5. Docs

- `README.md`: one sentence on the status line showing encryption.
- `docs/ROADMAP.md`: mark "Configurable failure policy" (encryption part) as
  done.

## Files to Modify

| File | Change |
|---|---|
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/ResolverStatusPresentation.swift` (new) | Item 1 |
| `ios/IBlockerKit/Sources/IBlockerUI/Dashboard/DashboardView.swift` | Item 2 |
| `ios/IBlockerKit/Sources/IBlockerUI/RootView.swift` | Tab selection (item 3) |
| `ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift` | Item 4 |
| `ios/IBlockerKit/Tests/IBlockerKitTests/ResolverStatusPresentationTests.swift` (new) | Tests |
| `README.md`, `docs/ROADMAP.md` | Item 5 |

## Logging

Follow [docs/LOGGING.md](../../docs/LOGGING.md).

| Event | Level | Category | Details |
|---|---|---|---|
| Dashboard status line tone changes (for example positive → warning) | `info` | ui | old → new tone and main line, at most once per change, never per poll |
| "DNS settings" button tapped | `debug` | ui | current status |

## Acceptance Criteria

Automated:

1. `ResolverStatusPresentation` returns exactly the icon, tone, main line,
   caption and `showsDNSSettingsButton` in the table for each of the six
   `resolverStatus` cases. It returns positive / "Protected — DNS filtering
   active" for `nil`.
2. IBlockerKit still builds and tests on Linux. The presentation doesn't use
   SwiftUI.
3. All existing tests pass.

Build:

4. `cd ios && xcodegen generate && xcodebuild build -project IBlocker.xcodeproj -scheme IBlocker -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`
   succeeds.

Code review:

5. `DashboardView.statusLine` and the Settings status both use
   `ResolverStatusPresentation`, so no strings are duplicated in the views.
   There's no separate encryption row or banner. The "DNS settings" button
   switches to the Settings tab.

On device (manual, by the user):

6. Alternative off: the status line shows the orange "Protected —
   unencrypted DNS (Network DNS)" with its caption.
7. Cloudflare: green "Protected — encrypted DNS (Cloudflare)".
8. Custom DoH `https://192.0.2.1/dns-query`, fallback on: within a few
   lookups, the orange "Protected — encrypted DNS unavailable" with its
   caption and button. The button opens Settings.
9. The same URL with fallback off: the red "DNS lookups are failing".
10. The top of Settings' DNS section matches the Dashboard's main line.

## Scope

**In scope:** items 1–5.

**Out of scope:** widgets, Control Center and notifications; any change to
resolver behaviour (that's `spec-c7e3c45d`).

## Pending Decisions

None.
