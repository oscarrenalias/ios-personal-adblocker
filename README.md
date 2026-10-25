# Personal Ad Blocker for iOS

A personal ad blocker for iPhone and iPad. It blocks ads and trackers in all
apps, not only in Safari. It runs entirely on the phone and sends no data
anywhere.

It's based on [Just an AdBlocker](https://github.com/AlmoutasemNabil/just-an-adblocker)
by Almoutasem Nabil (MIT license). The Android version was removed, and the
iOS history was kept.

## How it works

The app installs a VPN that runs on the phone itself. It doesn't send your
traffic to a server. It only handles DNS, the step where an app looks up the
address of a server such as `ads.example.com`:

- If the name is on a blocklist, the app answers "nowhere" (`0.0.0.0`), so the
  ad never loads.
- Otherwise it passes the lookup on to a DNS resolver. By default this is
  **Network DNS**: the resolver of the Wi-Fi or cellular network you're
  connected to. In Settings you can turn on an **alternative DNS** (an
  encrypted DNS provider using DNS over HTTPS, or a plain DNS server).

The alternative is used while it works. If it can't be reached (captive
Wi-Fi, a network that blocks DNS over HTTPS, a resolver outage), lookups fall
back to Network DNS, which is unencrypted, so the phone keeps working. The
alternative is retried in the background until it answers again. In Settings
you can choose **Don't fall back** instead, so lookups fail rather than leave
unencrypted. Names that only your local network or carrier can answer (router
pages, Wi-Fi calling) always use Network DNS. `.local` names are answered
"not found" inside the tunnel and resolve over multicast DNS outside it.

All other traffic goes straight to the internet as normal, so the VPN doesn't
slow down browsing or downloads.

There are also two optional extras:

- **Safari content blocker.** It hides empty ad boxes left on web pages.
- **DNS profile.** A settings profile that points the phone at a filtering DNS
  provider. It keeps some blocking in place when the VPN is off.

More detail is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/BLOCKING-MODES.md](docs/BLOCKING-MODES.md).

## Blocklists

A small built-in list covers Google's in-app ads (AdMob) and the main mobile ad
networks. It works from first launch, even offline. OISD Big is also on by
default. You can turn on StevenBlack and the AdGuard DNS filter, or add any
list by URL, in the app's **Lists** tab.

The app downloads lists directly from the people who publish them and updates
them automatically.

## What it can't do

- **YouTube and Facebook ads inside their own apps.** The ads come from the
  same servers as the videos and posts, so blocking by name can't separate
  them.
- **Apps that use their own encrypted DNS.** Some apps don't use the phone's
  DNS at all, so the blocker never sees their lookups.
- **Per-app rules.** iOS doesn't tell the VPN which app made a request.
- **Another VPN at the same time.** iOS only runs one VPN at a time.

## Build and install

You need:

- A Mac with a recent Xcode.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- A paid Apple Developer account. Apple only allows VPN apps with a paid
  account.
- An iPhone or iPad on iOS 18 or later.

Steps:

1. Set your Team ID and bundle ID prefix at the top of
   [`ios/project.yml`](ios/project.yml):
   ```yaml
   DEVELOPMENT_TEAM: QEZ63CXN26
   BUNDLE_ID_PREFIX: com.renalias
   ```
2. Generate the Xcode project and open it:
   ```bash
   cd ios
   xcodegen generate
   open IBlocker.xcodeproj
   ```
   The `.xcodeproj` file is generated and isn't in git. Run
   `xcodegen generate` again after you change `project.yml` or add files.
   Don't change build settings in Xcode itself, because the next generate
   overwrites them.
3. Choose the **IBlocker** scheme and your device, then press **Run**. On the
   first build, Xcode registers the app IDs, the App Group, and the VPN
   permission with your account.
4. On the phone, follow the setup screens. Tap **Enable protection** and
   allow the VPN when iOS asks.

More signing details are in [docs/SIGNING.md](docs/SIGNING.md).

## Check that it works

- In the app, go to **Settings ▸ Verify blocking**. It looks up some known ad
  domains and tells you whether they're blocked.
- Open a free game with ads. Force-quit it first, because apps often keep one
  ad stored in advance. The ad spaces should stay empty.
- The **Log** tab shows each lookup and whether it was blocked.

## Privacy

There's no server, account, analytics, or crash reporting. The app only
connects to:

- the DNS resolver, for lookups that aren't blocked. By default that is the
  resolver of your current network; if you turned on an alternative in
  Settings, it's that provider, and your network's resolver again whenever
  the alternative is unreachable and fallback is on
- the blocklist websites, when it updates lists

The log of lookups stays on the phone. It's a fixed-size file of about 4 MB
that overwrites itself, and you can turn it off in Settings. With the
default Network DNS, lookups that aren't blocked are visible to your network's
resolver (for example your home router or mobile carrier), the same as without
the app. If you use an encrypted DNS provider, that provider sees them instead
while it works.

## Project layout

```
ios/
  project.yml         XcodeGen spec: team, bundle IDs, build settings
  IBlockerKit/        Swift package with the logic, covered by unit tests
    Sources/IBlockerKit/        DNS parsing, packets, blocklists, query log,
                                resolver router and circuit breaker
    Sources/IBlockerTunnelKit/  Sends lookups on to the DNS resolver
    Sources/IBlockerUI/         The app's screens (SwiftUI)
  App/                The app target
  PacketTunnel/       The VPN extension
  ContentBlocker/     The Safari content blocker
  Widgets/            Home Screen widgets and a Control Center toggle
docs/                 Architecture, blocking modes, signing
specs/                Specs for planned work (takt)
```

## Tests

```bash
swift test --package-path ios/IBlockerKit
```

The tests don't need a phone or a simulator.

## License

MIT. See [LICENSE](LICENSE). The original copyright notice is kept, as the
license requires.
