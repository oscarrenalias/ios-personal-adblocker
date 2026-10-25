# Signing setup

## TL;DR

Edit the project-level `settings.base` in `ios/project.yml`:

```yaml
DEVELOPMENT_TEAM: ABCDE12345      # Team ID from developer.apple.com → Membership
BUNDLE_ID_PREFIX: net.yourname
```

Then `cd ios && xcodegen generate`, open `ios/IBlocker.xcodeproj`, select
your device, Run. Xcode's automatic signing registers everything (App IDs,
App Group, VPN capability) on first build. Never edit build settings in
Xcode's UI — the project is regenerated from `project.yml` and those edits
are lost.

## What gets derived

| Thing | Value |
|---|---|
| App bundle ID | `$(BUNDLE_ID_PREFIX).adblocker` |
| Tunnel extension | `$(BUNDLE_ID_PREFIX).adblocker.tunnel` |
| Safari blocker | `$(BUNDLE_ID_PREFIX).adblocker.blocker` |
| Widgets | `$(BUNDLE_ID_PREFIX).adblocker.widgets` |
| App Group | `group.$(BUNDLE_ID_PREFIX).adblocker` |

Extension IDs are prefixed by the app ID (an Apple requirement for embedded
extensions). The App Group is stamped into each target's Info.plist as
`AppGroupID` (how the code discovers it at runtime) and into each
`.entitlements` file as `$(APP_GROUP_ID)` — nothing is hardcoded in Swift or
in the entitlements.

## Why a paid account is required

The `com.apple.developer.networking.networkextension` entitlement
(`packet-tunnel-provider`) is only issued to paid Apple Developer accounts.
A free "Personal Team" build will fail signing for the app and tunnel
targets.

## Common issues

- **"Cannot create a … provisioning profile" / missing entitlement**: your
  account hasn't finished processing the capability. Wait a few minutes,
  re-run `xcodegen generate`, and build again. From the command line,
  `xcodebuild -allowProvisioningUpdates` makes Xcode fetch fresh profiles.
  Don't fix signing in Xcode's Signing & Capabilities tab — the next
  `xcodegen generate` discards those changes.
- **Upgrading from an earlier build with the old IDs**: the IDs,
  App Group and app name (now Personal AdBlocker) all changed, so the new
  build is a different app. Delete the old app first, run the setup again,
  and re-add the widgets.
- **App Group mismatch**: if you change `BUNDLE_ID_PREFIX` after a first
  install, delete the app from the device (the old VPN configuration
  references the old bundle ID) and reinstall.
- **On iOS betas**: after the very first install, reboot the device once if
  the VPN toggle doesn't stick — a long-standing NetworkExtension beta quirk.
- **7-day expiry** doesn't apply here: paid-account development builds last
  a year. Rebuild/redeploy whenever you update the app.
