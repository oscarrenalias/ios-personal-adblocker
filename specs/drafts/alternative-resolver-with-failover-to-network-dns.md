---
name: Alternative resolver with failover to network DNS
id: spec-c7e3c45d
description: "Tunnel side of KI-1 part 2: ResolverRouter with circuit breaker, fallback policy (network DNS or none), network-only names, .local NXDOMAIN, presets/settings/migration/IPC, minimal Settings controls"
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
DNS by default, or fail if the user has turned fallback off. The alternative
is retried until it works again. The tunnel reports which resolver is
answering and whether lookups are encrypted.

This is the tunnel and settings side. The Dashboard status line that shows
encryption state is a separate spec, "Encryption status in the Dashboard
status line", which depends on this one.

This fixes `docs/KNOWN-ISSUES.md` KI-1 (part 2 of 2) and KI-15.

**Depends on:** `spec-4cb10c45` (network DNS default), merged and verified on
device.

## Problems to Fix

- The tunnel forwards to exactly one upstream. If that upstream is a DoH or
  UDP resolver and it can't be reached, `DNSProxyEngine.forward`
  (`ios/IBlockerKit/Sources/IBlockerKit/Engine/DNSProxyEngine.swift`) returns
  SERVFAIL for every lookup, and the phone has no working DNS (captive-portal
  Wi-Fi, networks blocking 1.1.1.1 or DoH, resolver outages).
- Names that only the local network or carrier can answer (router pages,
  Wi-Fi calling servers) are sent to the public resolver too.
- iOS sends `SOA` lookups for `local` through the tunnel on every network
  change. They time out after 3 s via network DNS (KI-15).
- The tunnel doesn't report whether lookups are going out encrypted.

## Background and decisions

- **Circuit breaker, not per-query fallback.** AdGuard tries its primary on
  every query, so each lookup pays a timeout while the primary is down. Here,
  lookups skip a dead alternative, and it's re-probed lazily.
- **Architecture:** `DNSProxyEngine` keeps holding one `DNSUpstream` and
  **isn't changed**. A new `ResolverRouter` (in
  `ios/IBlockerKit/Sources/IBlockerKit/Engine/`) implements `DNSUpstream`. It
  wraps the network upstream and the optional alternative, and owns the
  breaker, the fallback policy, the network-only names and `.local`. It
  parses messages with `DNSParser` when it needs the name. Blocking stays in
  the engine, before the router.
- **Status reporting:** `PacketTunnelProvider` keeps a reference to the
  current router. In `handleAppMessage(.getStats)`
  (`ios/PacketTunnel/PacketTunnelProvider.swift`, around line 217) it takes
  `engine.statsSnapshot(...)` and sets `resolverStatus = router.status`
  before replying. The engine isn't involved.
- **Encrypted or not:** only DoH (`UpstreamConfig.Kind.doh`) is encrypted.
  `.network` and `.udp` are unencrypted. Expose this once, as
  `UpstreamConfig.isEncrypted`.
- **`.local`** is answered locally with NXDOMAIN, never forwarded. `.local`
  device names (for example `raspberrypi.local`) resolve over multicast DNS
  outside the tunnel, and NXDOMAIN for the `local` `SOA` check keeps iOS
  doing that. Decided with the user on 2026-10-25.
- **Battery:** no timers. Probes are triggered by queries and by network
  changes (KI-4).
- **Changing settings rebuilds the router,** so breaker state is reset on
  purpose.
- **Profiles** are out of scope (decided 2026-10-25).

## Changes

### 1. Circuit breaker (pure logic)

A `CircuitBreaker` value type with an injected clock (`() -> Date`), in
`ios/IBlockerKit/Sources/IBlockerKit/Engine/`.

- **States:** `healthy(consecutiveFailures)` and `down(nextProbeAt, backoff)`.
  A `generation: Int` increments on every trip and every reset.
- **Healthy:** a success sets the failure count to 0. A failure adds 1. At
  **3** it trips: `down`, `backoff = 30 s`, `nextProbeAt = tripTime + 30 s`,
  and the generation increments.
- **Down:** real queries never go to the alternative. When a query that would
  have gone to the alternative (router rules 4–5) arrives with
  `now >= nextProbeAt`, and no probe is running, one background probe starts.
  - Probe success → `healthy(0)`, generation increments.
  - Probe failure at time `t` → `backoff = min(backoff × 2, 300 s)`,
    `nextProbeAt = t + backoff`. After the trip the waits are 30 s, then
    60 s, 120 s, 240 s, 300 s, 300 s and so on, each measured from the
    previous probe's failure.
- **Recovery:** after returning to healthy, the next trip starts again at
  30 s.
- **Stale results:** every alternative query and probe records the
  generation it started in. Results from an older generation are ignored.
  This covers queries in flight during a trip, a reset or a network change.
- **Network change** (item 5): go to `healthy(0)`, increment the generation,
  and request one immediate probe. Any probe already running is ignored when
  it finishes, because its generation is old. The new probe's failure counts
  as one failure, so it doesn't trip the breaker on its own. If the
  alternative is off, a network change does nothing.

### 2. Network-only names (pure logic)

A fixed list in `IBlockerKit`. A name matches if it equals an entry or is a
subdomain of one. `*` matches exactly one label. These names always go to
`network`, under both fallback policies, and don't trigger probes. The engine
has already checked them against the blocklist.

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

(The Wi-Fi calling and router entries are a snapshot of the DnsLibs default
`fallback_domains` list, AdguardTeam/DnsLibs `proxy/dnsproxy.cpp` at
`57f11ac436`, 2026-07-20. That's a list of domain names, not code.
`local` is handled by router rule 1, not here.)

### 3. ResolverRouter

Implements `DNSUpstream`. It wraps `network: DNSUpstream`,
`alternative: (upstream: DNSUpstream, name: String, encrypted: Bool)?`,
`policy: FallbackPolicy` (`.networkDNS` | `.none`) and a `CircuitBreaker`.
Rules, in order:

1. **`local` / `*.local`** (any type): reply NXDOMAIN using
   `DNSResponseBuilder.nxdomain(for:)`. No upstream, no probe. This applies
   whether the alternative is on or off. Messages that can't be parsed can't
   be checked for `.local`, so they skip this rule.
2. **Alternative off:** everything goes to `network`.
3. **Network-only name:** goes to `network`.
4. **Alternative on and healthy:** query `alternative` with a **2 s** timeout
   that the router enforces itself (`DoHUpstream`/`UDPUpstream` defaults are
   unchanged). On success, record a success. On failure or timeout, record a
   failure, then:
   - `.networkDNS`: re-send the same query to `network` and return its
     result.
   - `.none`: throw, so the engine answers SERVFAIL.
5. **Alternative on and down:** if a probe is due, start one in the
   background. Then:
   - `.networkDNS`: go to `network`.
   - `.none`: throw.
6. **Unparseable messages:** if the alternative is on and healthy, rule 4
   applies. Otherwise:
   - `.networkDNS`: send them to `network` (which throws, so they're dropped,
     as today).
   - `.none`: drop them.
- **Probe:** an `A` query for `apple.com` (class IN, RD set) sent to the
  alternative with a 2 s timeout. A valid response with RCODE NOERROR counts
  as success.
- **No physical interface:** DoH and UDP upstreams aren't bound to an
  interface, so a healthy alternative is still tried. `network` throws, as
  today.
- `networkChanged()` → breaker network change (item 1).
- `status: ResolverStatus`:
  - alternative off → `network`
  - healthy → `alternative(name:encrypted:)`
  - down with `.networkDNS` → `fallingBack(name:)`
  - down with `.none` → `failing(name:)`

### 4. Presets, settings, migration and IPC

- **Presets move into `IBlockerKit`:** move the choices from the private
  `SettingsView.upstreamChoices` into `IBlockerKit` as
  `UpstreamPreset { name, label, config }` (for example
  `ios/IBlockerKit/Sources/IBlockerKit/Shared/UpstreamPreset.swift`). `name`
  is short and unique, and `label` is what the picker shows:

  | name | label | config |
  |---|---|---|
  | Cloudflare | Cloudflare (DoH) | DoH `https://1.1.1.1/dns-query` |
  | AdGuard DNS | AdGuard DNS (DoH, extra blocking) | DoH `https://94.140.14.14/dns-query` |
  | Quad9 | Quad9 (DoH, malware blocking) | DoH `https://9.9.9.9:5053/dns-query` |
  | Cloudflare (UDP) | Cloudflare (UDP 53, unencrypted) | UDP `1.1.1.1` |
  | Quad9 (UDP) | Quad9 (UDP 53, unencrypted) | UDP `9.9.9.9` |

  A config that matches no preset is named `"Custom"`. "Network DNS" isn't
  an alternative preset.
- **`ResolverSettings`** (Codable): `useAlternative: Bool`,
  `alternative: UpstreamConfig`, `alternativeName: String`,
  `fallbackPolicy: FallbackPolicy`. Stored as JSON under the shared-defaults
  key `resolverSettings` (`SharedSettings`,
  `ios/IBlockerKit/Sources/IBlockerKit/Shared/SharedSettings.swift`). Default:
  off, Cloudflare (DoH), `"Cloudflare"`, `.networkDNS`.
- **Migration is computed on read and doesn't write.** If
  `resolverSettings` is missing, derive the settings from the old
  `upstreamConfig`. Leave `upstreamConfig` untouched. The app writes
  `resolverSettings` only when the user changes a setting, so the app and the
  tunnel derive the same result and don't race.
  - `upstreamConfig` missing or `.network` → the defaults above.
  - DoH or UDP → `useAlternative = true`, that config, the matching preset
    name (or `"Custom"`), `.networkDNS`. An encrypted choice is never
    silently downgraded.
- **IPC:** replace `TunnelRequest.setUpstream(UpstreamConfig)` with
  `setResolverSettings(ResolverSettings)`
  (`ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelIPC.swift`). Replace
  `TunnelController.setUpstream`
  (`ios/IBlockerKit/Sources/IBlockerUI/System/TunnelController.swift`) with
  `setResolverSettings`. No dead IPC cases are left. `TunnelRuntimeStats`
  gains `resolverStatus: ResolverStatus?`, which is nil for older tunnels.

### 5. Tunnel wiring

In `ios/PacketTunnel/PacketTunnelProvider.swift`:

- Build a `ResolverRouter` from `ResolverSettings`: `network` from the
  existing `makeUpstream(UpstreamConfig(kind: .network))`, and the
  alternative from `makeUpstream(settings.alternative)` when
  `useAlternative` is on. Keep a reference to it, set it as the engine's
  upstream, and rebuild it on `setResolverSettings`.
- `.getStats` sets `resolverStatus` from the router (see Background).
- **Network change:** call `router.networkChanged()` only when the
  **selected physical interface changes**. That's the same condition as the
  existing `path` log line, not every path update.
- **Boot recovery** (`TunnelRecovery`, KI-16): while settings are unreadable,
  the router is built with defaults (alternative off). When settings become
  readable, rebuild it from `ResolverSettings`.

### 6. Minimal Settings controls

Replace the single upstream picker in
`ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift`
("Upstream DNS (VPN mode)" section) with:

- A toggle **"Use alternative DNS"**.
- When it's on:
  - a picker of `UpstreamPreset` labels, plus the existing custom DoH and UDP
    fields (custom entries are named `"Custom"`)
  - a picker **"If the alternative is unreachable"**:
    - **"Use network DNS (unencrypted)"**
    - **"Don't fall back (lookups fail)"**
- A footer: "Network DNS is used when this is off, when the alternative is
  unreachable (if fallback is on), and always for local and carrier names.
  .local names are handled by your local network."
- Each change writes `resolverSettings` and sends `setResolverSettings`.

The encryption status display is in the follow-up spec.

### 7. Docs

- `README.md` and `docs/ARCHITECTURE.md`: describe the router, the
  failover, the fallback policy and `.local`.
- `docs/KNOWN-ISSUES.md`: mark KI-1 and KI-15 as fixed, and link this spec.

## Files to Modify

| File | Change |
|---|---|
| `ios/IBlockerKit/Sources/IBlockerKit/Engine/` (new files) | `CircuitBreaker`, network-only names, `ResolverRouter`, `ResolverStatus` (items 1–3) |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/UpstreamPreset.swift` (new) | Presets (item 4) |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/SharedSettings.swift` | `ResolverSettings`, `FallbackPolicy`, migration (item 4) |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelIPC.swift` | IPC, `resolverStatus` in stats, `isEncrypted` (item 4) |
| `ios/PacketTunnel/PacketTunnelProvider.swift` | Router wiring, stats, network change, recovery (item 5) |
| `ios/IBlockerKit/Sources/IBlockerUI/System/TunnelController.swift` | `setResolverSettings` (item 4) |
| `ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift` | Minimal controls (item 6) |
| `ios/IBlockerKit/Tests/IBlockerKitTests/` | Tests |
| `README.md`, `docs/ARCHITECTURE.md`, `docs/KNOWN-ISSUES.md` | Docs (item 7) |

`DNSProxyEngine.swift` isn't changed.

## Logging

Follow [docs/LOGGING.md](../../docs/LOGGING.md) and use the `Log` wrapper.
Use category `router` for the router and breaker, `settings` for settings,
and `tunnel` for the provider. Network-change detection stays under `path`.

| Event | Level | Category | Details |
|---|---|---|---|
| Breaker trips | `notice` | router | alternative name, failure count, backoff, effect: "falling back to network DNS (unencrypted)" or "lookups failing (fallback off)" |
| Breaker recovers | `notice` | router | alternative name, time spent down |
| Probe started / succeeded / failed | `info` | router | name, duration, error, next probe time |
| Breaker reset by network change | `info` | router | generation |
| `ResolverStatus` changed | `notice` | router | old → new, encrypted yes/no |
| Resolver settings applied | `notice` | tunnel | source (start / ipc / recovery), toggle, alternative name and URL, policy |
| Migration derived from `upstreamConfig` | `notice` | settings | old kind → derived settings (no domains) |
| Query failed on alternative and was re-sent to network | `debug` | router | domain, qtype, error, elapsed ms |
| Routing decision | `debug` | router | domain, qtype, rule (local / off / network-only / alternative / fallback / failing) |
| Query failed with no fallback (SERVFAIL) | `debug` | router | domain, qtype, reason. The state change itself is logged once, by the trip notice. |
| `setResolverSettings` can't be applied or decoded | `error` | tunnel | reason |

## Acceptance Criteria

Automated (`swift test --package-path ios/IBlockerKit`, with fake upstreams
and an injected clock):

1. With the alternative off, the alternative is never called.
2. With the alternative healthy, queries go to the alternative. When it
   throws or takes more than 2 s, with policy `.networkDNS`, the same query
   is answered by `network`, and the client gets that answer, not SERVFAIL.
3. After 3 consecutive failures, the next query goes to `network` without
   calling the alternative.
4. Probe timing: after a trip at t0, the first probe is allowed at
   t0 + 30 s. After a probe fails at t1, the next one is allowed at t1 + 60 s,
   then + 120, + 240, + 300 and + 300 s. Only one probe runs at a time, and no
   probe starts without an incoming query that would have gone to the
   alternative.
5. A successful probe sends queries back to the alternative. The next trip
   starts with a 30 s backoff.
6. A network change resets the breaker to `healthy(0)` and triggers one
   probe. A single failed probe doesn't trip it. With the alternative off,
   a network change does nothing.
7. Stale results: a failure from a query or probe started before a trip or a
   reset doesn't change the state.
8. `1.168.192.in-addr.arpa`, `epdg.epc.mnc260.mcc310.pub.3gppnetwork.org`
   and `fritz.box` go to `network` under both policies and don't trigger a
   probe. `example.com` and `notlocal.com` don't match.
9. `local` (`SOA`) and `printer.local` (`A`) get NXDOMAIN with **no**
   upstream called, with the alternative on and off.
10. Policy `.none`: when the alternative fails or is down, the router throws
    and never calls `network`. Network-only names still go to `network`.
11. `router.status` and `isEncrypted`:
    - off → `network`, unencrypted
    - DoH healthy → `alternative`, encrypted
    - UDP healthy → `alternative`, unencrypted
    - down with `.networkDNS` → `fallingBack`, unencrypted
    - down with `.none` → `failing`, unencrypted
12. Through `DNSProxyEngine` with a `ResolverRouter` upstream, a blocked name
    never reaches any upstream.
13. With policy `.networkDNS`, if both upstreams fail, the client gets
    SERVFAIL.
14. Migration (`SharedSettingsTests`):
    - `upstreamConfig` missing or `.network` → `useAlternative == false`
    - DoH Cloudflare → `true`, name `"Cloudflare"`
    - UDP `9.9.9.9` → `true`, name `"Quad9 (UDP)"`
    - unknown DoH URL → `"Custom"`
    - all of them with `.networkDNS`
    - nothing is written when `resolverSettings` is missing
15. `ResolverSettings`, `ResolverStatus` and `TunnelRuntimeStats` (with and
    without `resolverStatus`) round-trip through `TunnelIPCCoder`.
16. All existing tests pass, and `IBlockerKit` still builds on Linux.

Code review:

17. `DNSProxyEngine.swift` is unchanged. `setUpstream` no longer exists in
    `TunnelIPC.swift` or `TunnelController.swift`. Every event in the Logging
    table is present, and domain names appear only in `debug` messages.

Build:

18. `cd ios && xcodegen generate && xcodebuild build -project IBlocker.xcodeproj -scheme IBlocker -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`
    succeeds.

On device (manual, by the user; check with a pymobiledevice3 log stream,
see docs/LOGGING.md):

19. With the alternative set to Cloudflare, the `router` category shows
    lookups going to the alternative.
20. With the custom DoH URL `https://192.0.2.1/dns-query` and fallback on,
    browsing keeps working, and the log shows a trip "falling back to network
    DNS (unencrypted)" and periodic probes.
21. The same URL with "Don't fall back": sites stop loading, and the log
    shows "lookups failing (fallback off)". Turning fallback back on restores
    browsing.
22. `raspberrypi.local` still resolves. On a network change, the `local`
    `SOA` lookups are answered at once, with no 3 s timeouts in the
    `network-dns` category.

## Scope

**In scope:** items 1–7.

**Out of scope:**
- The Dashboard and Settings encryption status line (follow-up spec).
- Widgets, Control Center and notifications for encryption state.
- DNS cache (KI-9), large answers and TCP (KI-2), new protocols, new
  presets.
- The "block everything while rules aren't loaded" policy (roadmap, health
  indicator).
- Profiles. Any third-party DNS library.

## Pending Decisions

- **Retry timings** (3 failures, 2 s timeout, 30 s to 300 s backoff) are
  starting values. Revisit after use.
- **Probe target:** `apple.com A`. Change it if a list ever blocks it.
