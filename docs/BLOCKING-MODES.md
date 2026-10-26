# Blocking modes and how they interact

Personal AdBlocker gives you three independent ways to block ads, plus a Safari
cosmetic layer. They can coexist; iOS picks the resolver by fixed precedence.

## 1. VPN mode (the main one)

On-device packet tunnel. Blocking decisions are made locally against your
compiled filter lists; non-blocked queries go to the upstream you chose
(encrypted DoH by default).

A built-in "Core mobile ad networks" ruleset ships inside the app binary and
is always compiled in (toggleable in Lists). It guarantees the floor — Google
in-app ads (AdMob) and the major mobile ad SDKs are blocked even before the
first list download, offline, or during a list-server outage.

- ✅ Works in every app, blocklist is yours, query log, allow/deny
- ✅ Nothing is routed through anyone's server (only DNS goes to the upstream)
- ⚠️ Occupies the device's one active VPN slot — can't run another VPN at
  the same time

## 2. DNS profile (.mobileconfig)

Settings ▸ Export a profile pointing system DNS at a filtering provider
(AdGuard DNS, Mullvad ad-blocking, NextDNS with your config ID…). The
*provider* does the blocking, not your lists.

- ✅ No VPN slot used; survives anything; zero battery cost
- ✅ Works even if you later stop sideloading the app
- ⚠️ Blocking policy is the provider's (NextDNS gives you control)
- Install flow: generate → share to yourself → open → Settings ▸ General ▸
  VPN & Device Management ▸ Profile Downloaded ▸ Install

## 3. System encrypted DNS (NEDNSSettingsManager)

Same effect as the profile, but installed programmatically from the app —
no file shuffling. Activate it once in Settings ▸ General ▸ VPN & Device
Management ▸ DNS.

## Precedence (what actually resolves your DNS)

```
active VPN tunnel DNS  >  DNS profile / NEDNSSettings  >  network's DHCP DNS
```

So: while the app's VPN is connected, its filtering wins. The moment the
VPN is off (you toggled it, or iOS killed it), an installed profile takes
over automatically. Running mode 1 + mode 2 together is the recommended
belt-and-suspenders setup — there is never a moment with unfiltered DNS.

## Safari content blocker (cosmetic layer)

DNS blocking stops requests, but pages sometimes keep empty ad frames or
"ad blocker detected" leftovers. The Safari extension applies EasyList's
element-hiding rules (the supported subset) inside Safari. Enable it in
Settings ▸ Apps ▸ Safari ▸ Extensions, refresh its rules from Personal AdBlocker's
Settings tab.

## Apple Private Relay and "Limit IP Address Tracking"

**Shipped behaviour:** the app does nothing special about Apple's relays.
The relay controls are hidden (`FeatureFlags.showAppleRelayControls =
false`). The effective strategy is `blockDomains`, but the bundled relay list
(`bundled-apple-relay`) is never compiled, so no Apple relay domains are
blocked. The tunnel claims only the DNS route, not the default route.
Private Relay and Limit IP Address Tracking keep working while protection
runs.

**Measured on device (2026-10-26, iOS 18, encrypted resolver, OISD plus the
built-in rules).** The same three checks were run with each setting
combination:
- the adblock.turtlecute.org test page in Safari;
- an ad-supported game (Sudoku.com);
- the tunnel's per-query logs.

| Setting | Safari lookups reach the blocker | Test page score | In-app ads |
|---|---|---|---|
| Both off | yes | 90% (missed domains were cached while protection was off) | blocked |
| Limit IP Address Tracking on | yes | 94% | blocked |
| Plus iCloud Private Relay on | yes | 94% (same misses) | blocked |

What that means:
- **Private Relay doesn't take Safari out of the filter** while this VPN is
  running. Safari's lookups, for example `www.bbc.com`, still reached the
  tunnel and went out over the encrypted resolver, and blocking was
  unchanged. Private Relay's own endpoints (`mask.apple-dns.net`,
  `mask-api.icloud.com`) were looked up and allowed.
- **Limit IP Address Tracking lets a few Safari tracker connections
  through.** One known tracker, `weather-analytics-events.apple.com`, loaded
  on the test page even though the tunnel blocked its lookup. Safari sent
  that connection through Apple's relay, which resolves the name itself.
  This affected 1 of 132 test domains.
- **In-app ads are unaffected by either setting.** Apps resolve their ad
  networks through system DNS, and those were blocked in every phase:
  - AppLovin
  - Moloco
  - Mintegral
  - Unity Ads
  - Amazon
- **The remaining test-page misses were gaps in the lists** (for example
  `ads.tiktok.com`, `sessions.bugsnag.com`, `browser.sentry-cdn.com`), not
  the relay. Adding HaGeZi Pro narrows them.

**Why relay blocking stays off:** blocking the relay endpoints, or claiming
the default route so that iOS suspends the relays (`autoSuspend`), would
break Private Relay for the whole phone. That's too high a price for the
handful of Safari tracker connections that Limit IP Address Tracking
carries. The Safari content blocker also applies inside WebKit, whatever
path the network traffic takes. The `RelayStrategy` code stays in place
behind the flag in case this changes.

**If you want those last Safari trackers filtered too:** turn off Limit IP
Address Tracking in Settings ▸ Wi-Fi ▸ ⓘ (for each network) and in
Settings ▸ Cellular ▸ Cellular Data Options. Tracker connections then go
direct, and the DNS blocking applies to them.

## What none of these can do

- Apps with **hardcoded DoH** (some browsers) can skip system DNS entirely.
  The default lists block major DoH endpoints, which pushes those apps back
  to system DNS, but it's an arms race.
- **YouTube/Facebook in-app ads** are served from the same domains as
  content — DNS-level blocking cannot separate them. (Nothing on iOS can,
  short of MITM proxies with their own problems.)
- Traffic pinned to IP addresses without DNS lookups.
