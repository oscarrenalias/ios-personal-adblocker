---
name: Alternative resolver with failover to network DNS
id: spec-c7e3c45d
description: "Optional alternative resolver with circuit-breaker failover to network DNS and network-only names; KI-1 part 2, depends on spec-4cb10c45 verified on device"
dependencies: null
priority: high
complexity: null
status: draft
tags:
- dns
- tunnel
- resilience
scope:
  in: null
  out: null
feature_root_id: null
---
# Alternative resolver with failover to network DNS

## Objective

Let the user turn on an alternative resolver (Cloudflare, Quad9 and so on).
It's used while it's reachable. When it isn't, lookups fall back to network
DNS by default, and the alternative is retried until it works again. The user
can choose to never fall back, so lookups fail instead of going unencrypted.
The app always makes it clear and obvious when lookups are going out
unencrypted.

This is part 2 of 2 for `docs/KNOWN-ISSUES.md` KI-1.

**Depends on:** "Network DNS as the default resolver" (`spec-4cb10c45`) being
merged **and verified on device** (its criteria 9–12). Don't plan this spec
before then.

## Problems to Fix

- After part 1, the user picks exactly one upstream. If that upstream is a
  DoH or UDP resolver and it can't be reached, `DNSProxyEngine.forward`
  (`ios/IBlockerKit/Sources/IBlockerKit/Engine/DNSProxyEngine.swift`) returns
  SERVFAIL for every lookup, and the phone has no working DNS (captive-portal
  Wi-Fi, networks blocking 1.1.1.1 or DoH, resolver outages).
- Names that only the local network or carrier can answer (router pages,
  Wi-Fi calling servers) are sent to the public resolver too.
- The app never says whether lookups are encrypted. Network DNS and the UDP
  choices send lookups in plain text, but the Settings label is the only
  hint.
- iOS sends `SOA` lookups for `local` through the tunnel on every network
  change. They time out after 3 s via network DNS (`docs/KNOWN-ISSUES.md`
  KI-15).

## Background and decisions

- **Retrying differs from AdGuard on purpose.** AdGuard tries its primary on
  every query and falls back per query, so every lookup pays a timeout while
  the primary is down. This spec uses a circuit breaker so lookups skip a dead
  alternative.
- **Architecture:** `DNSProxyEngine` keeps holding **one** `DNSUpstream`. A
  new `ResolverRouter` (in `ios/IBlockerKit/Sources/IBlockerKit/Engine/`)
  implements `DNSUpstream` and wraps the network upstream and the optional
  alternative upstream. It owns the circuit breaker and the network-only name
  rules. It parses messages with `DNSParser` itself when it needs the name.
  `DNSProxyEngine` itself isn't changed, so blocking stays first and
  unchanged.
- **Battery:** no timers. Probes are triggered lazily by incoming queries and
  by network-change events (see `docs/KNOWN-ISSUES.md` KI-4).
- **Encrypted or not:** only DoH (`UpstreamConfig.Kind.doh`) is encrypted.
  Network DNS (`.network`) and UDP (`.udp`) are unencrypted. Derive this from
  the kind in one place (for example `UpstreamConfig.isEncrypted`), and
  don't duplicate it.
- **`.local`:** answered locally with NXDOMAIN, never forwarded. iOS
  resolves `.local` device names (for example `raspberrypi.local`) over
  multicast DNS outside the tunnel, so this doesn't affect them. NXDOMAIN for
  the `local` `SOA` check keeps iOS using multicast DNS. Decided with the
  user on 2026-10-25.
- **Profiles** are out of scope (decided 2026-10-25).

## Changes

### 1. Circuit breaker (pure logic)

A `CircuitBreaker` value type with an injected clock (`() -> Date`), in
`ios/IBlockerKit/Sources/IBlockerKit/Engine/`. These rules are fixed:

- **States:** `healthy(consecutiveFailures)` and `down(nextProbeAt, backoff)`.
- **Healthy:** a success resets the failure count to 0. A failure adds 1. At
  **3** it goes to `down` with backoff **30 s** and
  `nextProbeAt = now + 30 s`.
- **Down:** real queries never go to the alternative. When a query arrives
  and `now >= nextProbeAt`, one background probe is allowed. On probe
  success → `healthy(0)`. On probe failure, the backoff doubles (30, 60, 120,
  240 s, then capped at **300 s**) and `nextProbeAt = now + backoff`. Only
  one probe runs at a time.
- **Recovery:** after going back to healthy, the next trip starts again at
  30 s.
- **Late results:** results from queries sent before the breaker went down
  don't change its state while it's down.
- **Network change:** go to `healthy(0)` and request an immediate probe. A
  failed probe counts as one failure, so it doesn't trip the breaker on its
  own.

### 2. Network-only names (pure logic)

A fixed list in `IBlockerKit`. A name matches if it equals an entry or is a
subdomain of one. Entries with `*` match exactly one label in that position.
These names always go to network DNS, whatever the breaker state. They are
still checked against the blocklist first, because the engine does that
before calling the upstream.

```
lan
home.arpa
service.arpa
b._dns-sd._udp.*.in-addr.arpa
lb._dns-sd._udp.*.in-addr.arpa
10.in-addr.arpa
16.172.in-addr.arpa … 31.172.in-addr.arpa   (16 entries)
168.192.in-addr.arpa
d.f.ip6.arpa
pub.3gppnetwork.org
epdg.epc.aptg.com.tw
epdg.epc.att.net
epdg.mobileone.net.sg
primgw.vowifina.spcsdns.net
swu-loopback-epdg.qualcomm.com
vowifi.jio.com
weconnect.globe.com.ph
wlan.three.com.hk
wo.vzwwo.com
dengon.docomo.ne.jp
dlinkap
dlinkrouter
edimax.setup
fritz.box
gateway.2wire.net
miwifi.com
my.firewall
my.keenetic.net
netis.cc
pocket.wifi
router.asus.com
repeater.asus.com
routerlogin.com
routerlogin.net
tendawifi.com
tendawifi.net
tplinklogin.net
tplinkwifi.net
tplinkrepeater.net
oppowifi.com
myrepeater.net
mywifi.net
setup.pix-link.net
tplinkdeco.net
tplinkextender.net
www.asusrouter.com
```

(Wi-Fi calling and router entries are a snapshot of the DnsLibs default
`fallback_domains` list, AdguardTeam/DnsLibs `proxy/dnsproxy.cpp` at
`57f11ac436`, 2026-07-20. That's a list of domain names, not code.
`pub.3gppnetwork.org` covers the standard 3GPP ePDG names.)

**`local` is not on this list.** It's handled by the router itself (item 3).

### 3. ResolverRouter

Implements `DNSUpstream`, wrapping `network: DNSUpstream`,
`alternative: DNSUpstream?`, a `CircuitBreaker` and a `FallbackPolicy`
(`.networkDNS` or `.none`, item 4). The engine has already checked the
blocklist before the router is called.

Rules, in this order:

1. **`local` and `*.local`:** answered by the router itself with NXDOMAIN,
   for any query type (build the reply with `DNSResponseBuilder.nxdomain`).
   No upstream is called. This applies whether the alternative is on or off.
2. **Alternative off (nil):** everything goes to `network`.
3. **Network-only name** (item 2): goes to `network`, under both fallback
   policies. These names can only be answered by the local network or the
   carrier.
4. **Alternative on and healthy:** try `alternative` with a **2 s** timeout
   that the router enforces itself (don't change the `DoHUpstream` or
   `UDPUpstream` defaults). On success, record the success and return the
   answer. On failure or timeout, record the failure, then:
   - policy `.networkDNS`: immediately re-send the same query to `network`
     and return its result.
   - policy `.none`: throw, so the engine answers SERVFAIL. Never call
     `network`.
5. **Alternative on and down:**
   - policy `.networkDNS`: go to `network`.
   - policy `.none`: throw immediately (SERVFAIL) without calling either
     upstream.

   In both cases, if a probe is due, start one in the background.
- **Probe:** an `A` query for `apple.com` (class IN, RD set) sent to the
  alternative with a 2 s timeout. Any valid response with RCODE NOERROR
  counts as success.
- **Unparseable messages:** send to `alternative` if it's on and healthy.
  Otherwise, with policy `.networkDNS` send them to `network` (which throws,
  so they're dropped, as today), and with policy `.none` drop them.
- **No physical interface:** if the alternative is on and healthy, it's still
  tried. Otherwise the network upstream throws, which gives SERVFAIL.
- `networkChanged()` resets the breaker (item 1). `status` reports the
  current state (item 6).

### 4. Settings, migration and IPC

- New `ResolverSettings`: `useAlternative: Bool`,
  `alternative: UpstreamConfig`, `alternativeName: String`,
  `fallbackPolicy: FallbackPolicy` (`.networkDNS` | `.none`). Stored in
  `SharedSettings`
  (`ios/IBlockerKit/Sources/IBlockerKit/Shared/SharedSettings.swift`).
  Default: `useAlternative = false`, alternative = Cloudflare DoH, name
  `"Cloudflare"`, `fallbackPolicy = .networkDNS`.
- **Migration from part 1's single `upstreamConfig`:**
  - If the stored config is `.network`, or nothing is stored: use the
    defaults above.
  - If the stored config is DoH or UDP: `useAlternative = true`, with that
    config as the alternative. The name is the matching preset's name, or
    `"Custom"`. The user's encrypted choice is kept, never silently
    downgraded.
- IPC: replace `TunnelRequest.setUpstream` with
  `setResolverSettings(ResolverSettings)`
  (`ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelIPC.swift`). Apply it to
  a running tunnel without restarting.

### 5. Tunnel wiring

`ios/PacketTunnel/PacketTunnelProvider.swift`:
- Build a `ResolverRouter` from `ResolverSettings`: the network upstream from
  part 1, plus `UpstreamFactory.make(alternative)` when `useAlternative` is
  on.
- Call `networkChanged()` on every `NWPathMonitor` path change (part 1
  already has the monitor).
- **Boot recovery:** the provider already re-applies the upstream once
  settings become readable after the first unlock (`TunnelRecovery`,
  `docs/KNOWN-ISSUES.md` KI-16). That path must now rebuild the router from
  `ResolverSettings`, not from the old single `upstreamConfig`.

### 6. Status

- `TunnelRuntimeStats` gains `resolverStatus: ResolverStatus`, with cases:
  - `network`
  - `alternative(name: String, encrypted: Bool)`
  - `fallingBack(name: String)`: alternative down, policy `.networkDNS`
  - `failing(name: String)`: alternative down, policy `.none`

  `ResolverStatus.isEncrypted` is false for `network` and `fallingBack`.
  For `alternative` it follows the config's kind (DoH yes, UDP no).
- Exact UI strings for the status line:
  - `network` → **"Network DNS"**
  - `alternative(name, _)` → **"<name>"**, e.g. "Cloudflare"
  - `fallingBack(name)` → **"Network DNS — <name> unreachable, retrying"**
  - `failing(name)` → **"<name> unreachable — lookups are failing (fallback is off)"**
- Shown on the Dashboard
  (`ios/IBlockerKit/Sources/IBlockerUI/Dashboard/DashboardView.swift`) and
  in the DNS section of Settings.
- Map the status to strings, icons and colours in one place (for example a
  `ResolverStatusPresentation` in `IBlockerKit`) that both screens use and
  that tests cover. Same pattern as the existing `RulesTilePresentation`.

### 7. Encryption visibility

The user must be able to tell at a glance whether lookups are currently going
out unencrypted.

- **Dashboard: DNS encryption row**, always visible while protection is on,
  directly under the protection status:
  - Encrypted: `lock.fill`, green, **"Encrypted DNS · <name>"**.
  - Unencrypted by choice (`network`, or a UDP alternative): `lock.open.fill`,
    orange, **"Unencrypted DNS · <name or Network DNS>"**. Caption: **"Your
    network or DNS provider can see the sites you look up."**
- **Dashboard: fallback banner**, shown at the top of the Dashboard, above
  everything else, whenever the status is `fallingBack` or `failing`:
  - `fallingBack`: orange background, `exclamationmark.triangle.fill`.
    Title **"Encrypted DNS unavailable"**. Body **"<name> can't be reached.
    Lookups are going unencrypted to your network's DNS until it's back."**
    Button **"DNS settings"** opens the DNS section of Settings.
  - `failing`: red background. Title **"DNS lookups are failing"**. Body
    **"<name> can't be reached and fallback is off. Turn on fallback to stay
    connected (unencrypted)."** Same button.
- **Settings:** the same status line and icon at the top of the DNS section.
- When the tunnel's stats aren't reachable, show neither the row nor the
  banner. Show the existing "Tunnel not reachable" state instead. Never
  guess.

### 8. Settings UI

In `ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift`, replace
the single upstream picker with:

- A toggle **"Use alternative DNS"**.
- When it's on:
  - A picker with the existing DoH and UDP choices (without "Network DNS"),
    plus the existing custom DoH and UDP fields. Custom entries get the name
    "Custom". Label UDP choices **"(unencrypted)"**, for example
    "Cloudflare (UDP 53, unencrypted)".
  - A picker **"If the alternative is unreachable"** with:
    - **"Use network DNS (unencrypted)"** → `.networkDNS`
    - **"Don't fall back (lookups fail)"** → `.none`
- A footer explaining that network DNS is used when the toggle is off, when
  the alternative is unreachable (if fallback is on), and always for local
  and carrier names. `.local` names are handled by your local network,
  outside the app.

### 9. Docs

- `README.md` and `docs/ARCHITECTURE.md`: describe the failover, the
  fallback policy and the encryption indicator.
- `docs/KNOWN-ISSUES.md`: mark KI-1 and KI-15 as fixed, and link this spec.
- `docs/ROADMAP.md`: mark "Configurable failure policy" (encryption part) as
  done.

## Files to Modify

| File | Change |
|---|---|
| `ios/IBlockerKit/Sources/IBlockerKit/Engine/` (new files) | `CircuitBreaker`, network-only names, `ResolverRouter` (items 1–3) |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/SharedSettings.swift` | `ResolverSettings`, `FallbackPolicy`, migration (item 4) |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelIPC.swift` | IPC request, `ResolverStatus` in stats, `UpstreamConfig.isEncrypted` (items 4, 6) |
| `ios/IBlockerKit/Sources/IBlockerKit/` (new file) | `ResolverStatusPresentation` (item 6) |
| `ios/PacketTunnel/PacketTunnelProvider.swift` | Build the router, forward path changes, boot recovery (item 5) |
| `ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift` | Toggle, pickers, footer, status (items 6–8) |
| `ios/IBlockerKit/Sources/IBlockerUI/Dashboard/DashboardView.swift` | Encryption row, fallback banner (item 7) |
| `ios/IBlockerKit/Sources/IBlockerUI/System/TunnelController.swift` | Send `setResolverSettings` |
| `ios/IBlockerKit/Tests/IBlockerKitTests/` | Tests for the breaker, names, router, policy, presentation, settings and IPC |
| `README.md`, `docs/ARCHITECTURE.md`, `docs/KNOWN-ISSUES.md`, `docs/ROADMAP.md` | Docs (item 9) |

`DNSProxyEngine.swift` should not need changes.

## Logging

Follow [docs/LOGGING.md](../../docs/LOGGING.md): subsystem `com.iblocker`, and
the Linux-safe wrapper in `IBlockerKit`, which is created here if it doesn't
exist yet. Categories: `router` (router and breaker), `settings`, `tunnel`.

| Event | Level | Details to include |
|---|---|---|
| Breaker trips (healthy → down) | `notice` | alternative name, failure count, backoff, **and the effect: "falling back to network DNS (unencrypted)" or "lookups failing (fallback off)"** |
| Resolver status changes (any `ResolverStatus` transition) | `notice` | old → new status, encrypted yes/no |
| `.local` query answered locally | `debug` | domain, qtype |
| Breaker recovers (down → healthy) | `notice` | alternative name, how long it was down |
| Probe started / succeeded / failed | `info` | alternative name, duration, error on failure, next probe time |
| Network change resets the breaker | `info` | old → new interface name |
| Resolver settings applied (IPC, start or boot recovery) | `notice` | toggle on/off, alternative name and URL, fallback policy |
| Migration from old `upstreamConfig` | `notice` | old kind → new settings (no domains) |
| Query failed on alternative, re-sent to network | `debug` | domain, qtype, error, elapsed ms |
| Routing decision per query | `debug` | domain, qtype, target (alternative / network / network-only name) |
| Both upstreams failed (SERVFAIL) | `error` | qtype, both errors; domain only in a separate `debug` line |
| IPC `setResolverSettings` can't be applied or decoded | `error` | reason |

## Acceptance Criteria

Automated (`swift test --package-path ios/IBlockerKit`, with fake upstreams
and an injected clock):

1. With the alternative off, the router never calls the alternative.
2. With the alternative healthy, queries go to the alternative. When the
   alternative throws or takes longer than 2 s, the same query is answered
   by `network`, and the client gets that answer, not SERVFAIL.
3. After 3 consecutive alternative failures, the next query goes to
   `network` without calling the alternative.
4. While down, probes run only on the first query at or after 30 s, 60 s,
   120 s, 240 s, 300 s and then every 300 s. Only one probe runs at a time.
   No probes run without incoming queries.
5. A successful probe makes queries go to the alternative again. The next
   trip starts with a 30 s backoff.
6. A network-change event resets to `healthy(0)` and triggers one probe. A
   single failed probe does not trip the breaker.
7. A failure from a query sent before the trip doesn't change the state
   while the breaker is down.
8. `1.168.192.in-addr.arpa`, `epdg.epc.mnc260.mcc310.pub.3gppnetwork.org`
   and `fritz.box` go to `network` with the alternative healthy, under both
   fallback policies. `example.com` and `notlocal.com` don't match.
9. `local` (`SOA`) and `printer.local` (`A`) get NXDOMAIN from the router
   with **no** upstream called, with the alternative on and with it off.
10. Policy `.none`: when the alternative fails on a query, or is down, the
   router throws (the client gets SERVFAIL) and never calls `network`.
   Network-only names still go to `network`.
11. `ResolverStatus` and `isEncrypted` are correct for each case: network →
   unencrypted. DoH alternative healthy → encrypted. UDP alternative healthy
   → unencrypted. `fallingBack` → unencrypted. `failing` → no lookups.
12. `ResolverStatusPresentation` returns the exact strings, icons and colours
   in item 7 for each status, including the banner for `fallingBack` and
   `failing`, and no banner otherwise.
13. Through `DNSProxyEngine` with a `ResolverRouter` upstream, a blocked name
   never reaches either upstream, including blocked names under network-only
   zones.
14. If both upstreams fail, the client gets SERVFAIL.
15. Migration: no stored config or a stored `.network` config gives
    `useAlternative == false`. A stored DoH config gives
    `useAlternative == true` with that config kept. Migrated settings always
    have `fallbackPolicy == .networkDNS`.
16. `ResolverSettings` and `ResolverStatus` round-trip through
    `TunnelIPCCoder`.
17. All existing tests pass.

Code review:

18. Every event in the Logging table is logged at the stated level through
    `os.Logger` (or the `IBlockerKit` wrapper) with subsystem `com.iblocker`.
    Domain names appear only in `debug` messages. `IBlockerKit` still builds
    and tests on Linux.

Build:

19. `cd ios && xcodegen generate && xcodebuild build -project IBlocker.xcodeproj -scheme IBlocker -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`
    succeeds.

On device (manual, by the user):

20. With the alternative off, the Dashboard shows "Network DNS".
21. With the alternative set to Cloudflare, the Dashboard shows "Cloudflare".
22. With a custom DoH URL `https://192.0.2.1/dns-query` (unreachable) and
    fallback on, browsing still works. After a few lookups, the Dashboard
    shows the orange "Encrypted DNS unavailable" banner and the status
    "Network DNS — Custom unreachable, retrying". After switching to
    Cloudflare the banner disappears and the row shows the green "Encrypted
    DNS · Cloudflare".
23. Same unreachable URL with **"Don't fall back"**: sites stop loading, and
    the red "DNS lookups are failing" banner shows. Switching fallback back
    on restores browsing.
24. With the alternative off, the Dashboard shows the orange "Unencrypted DNS
    · Network DNS" row with its caption.
25. `raspberrypi.local` (or any `.local` device) still resolves with the
    alternative on and off. In a log stream, the `local` `SOA` lookups on a
    network change are answered at once, not after 3 s.

## Scope

**In scope:** items 1–9.

**Out of scope:**
- Showing encryption state in widgets or Control Center, and notifications
  when falling back. Possible follow-ups.
- The "block everything while rules aren't loaded" filtering policy. That's
  in the roadmap, under the health indicator.
- Protection profiles.
- DNS cache (KI-9). Large answers and TCP (KI-2).
- New protocols (DoT, DoQ, DNSCrypt) or new provider presets.
- "System encrypted DNS" (`DNSSettingsView`) and the profile export.
- Any third-party DNS library.

## Pending Decisions

- **Retry timings** (3 failures, 2 s timeout, 30 s to 300 s backoff) are
  starting values. Revisit after use.
- **Probe target** `apple.com A`. Change it if it's ever blocked by a list.
