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
DNS, and the alternative is retried until it works again.

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
  `.local`, Wi-Fi calling servers) are sent to the public resolver too.

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
local
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

### 3. ResolverRouter

Implements `DNSUpstream`, wrapping `network: DNSUpstream`,
`alternative: DNSUpstream?` and a `CircuitBreaker`.

- **Alternative off (nil):** everything goes to `network`.
- **Network-only name:** goes to `network`.
- **Alternative on and healthy:** try `alternative` with a **2 s** timeout
  that the router enforces itself (don't change the `DoHUpstream` or
  `UDPUpstream` defaults). On success, record the success and return the
  answer. On failure or timeout, record the failure and immediately re-send
  the same query to `network`, returning its result.
- **Alternative on and down:** go to `network`. If a probe is due, start one
  in the background.
- **Probe:** an `A` query for `apple.com` (class IN, RD set) sent to the
  alternative with a 2 s timeout. Any valid response with RCODE NOERROR
  counts as success.
- **Unparseable messages:** send to `alternative` if it's on and healthy,
  otherwise to `network` (which throws, so they're dropped, as today).
- **No physical interface:** if the alternative is on and healthy, it's still
  tried. Otherwise the network upstream throws, which gives SERVFAIL.
- `networkChanged()` resets the breaker (item 1). `status` reports the
  current state (item 6).

### 4. Settings, migration and IPC

- New `ResolverSettings`: `useAlternative: Bool`,
  `alternative: UpstreamConfig`, `alternativeName: String`. Stored in
  `SharedSettings`
  (`ios/IBlockerKit/Sources/IBlockerKit/Shared/SharedSettings.swift`).
  Default: `useAlternative = false`, alternative = Cloudflare DoH, name
  `"Cloudflare"`.
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

### 6. Status

- `TunnelRuntimeStats` gains
  `resolverStatus: ResolverStatus`, with cases `network`,
  `alternative(name: String)` and `alternativeDown(name: String)`.
- Exact UI strings:
  - `network` → **"Network DNS"**
  - `alternative(name)` → **"<name>"**, e.g. "Cloudflare"
  - `alternativeDown(name)` → **"Network DNS — <name> unreachable, retrying"**
- Shown on the Dashboard
  (`ios/IBlockerKit/Sources/IBlockerUI/Dashboard/DashboardView.swift`) and
  in the DNS section of Settings.

### 7. Settings UI

In `ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift`, replace
the single upstream picker with:

- A toggle **"Use alternative DNS"**.
- When it's on: a picker with the existing DoH and UDP choices (without
  "Network DNS"), plus the existing custom DoH and UDP fields. Custom entries
  get the name "Custom".
- A footer explaining: network DNS is used when the toggle is off, when the
  alternative is unreachable, and always for local and carrier names.

### 8. Docs

- `README.md` and `docs/ARCHITECTURE.md`: describe the failover.
- `docs/KNOWN-ISSUES.md`: mark KI-1 as fixed and link both specs.

## Files to Modify

| File | Change |
|---|---|
| `ios/IBlockerKit/Sources/IBlockerKit/Engine/` (new files) | `CircuitBreaker`, network-only names, `ResolverRouter` (items 1–3) |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/SharedSettings.swift` | `ResolverSettings` and migration (item 4) |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelIPC.swift` | IPC request, `ResolverStatus` in stats (items 4, 6) |
| `ios/PacketTunnel/PacketTunnelProvider.swift` | Build the router, forward path changes (item 5) |
| `ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift` | Toggle, picker, footer, status (items 6, 7) |
| `ios/IBlockerKit/Sources/IBlockerUI/Dashboard/DashboardView.swift` | Status (item 6) |
| `ios/IBlockerKit/Sources/IBlockerUI/System/TunnelController.swift` | Send `setResolverSettings` |
| `ios/IBlockerKit/Tests/IBlockerKitTests/` | Tests for the breaker, names, router, settings and IPC |
| `README.md`, `docs/ARCHITECTURE.md`, `docs/KNOWN-ISSUES.md` | Docs (item 8) |

`DNSProxyEngine.swift` should not need changes.

## Logging

Follow [docs/LOGGING.md](../../docs/LOGGING.md): subsystem `com.iblocker`, and
the Linux-safe wrapper in `IBlockerKit`, which is created here if it doesn't
exist yet. Categories: `router` (router and breaker), `settings`, `tunnel`.

| Event | Level | Details to include |
|---|---|---|
| Breaker trips (healthy → down) | `notice` | alternative name, failure count, backoff |
| Breaker recovers (down → healthy) | `notice` | alternative name, how long it was down |
| Probe started / succeeded / failed | `info` | alternative name, duration, error on failure, next probe time |
| Network change resets the breaker | `info` | old → new interface name |
| Resolver settings applied (IPC or start) | `notice` | toggle on/off, alternative name and URL |
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
8. `printer.local`, `1.168.192.in-addr.arpa`,
   `epdg.epc.mnc260.mcc310.pub.3gppnetwork.org` and `fritz.box` go to
   `network` with the alternative healthy. `example.com` and `notlocal.com`
   don't match.
9. Through `DNSProxyEngine` with a `ResolverRouter` upstream, a blocked name
   never reaches either upstream, including blocked names under network-only
   zones.
10. If both upstreams fail, the client gets SERVFAIL.
11. Migration: no stored config or a stored `.network` config gives
    `useAlternative == false`. A stored DoH config gives
    `useAlternative == true` with that config kept.
12. `ResolverSettings` and `ResolverStatus` round-trip through
    `TunnelIPCCoder`.
13. All existing tests pass.

Code review:

14. Every event in the Logging table is logged at the stated level through
    `os.Logger` (or the `IBlockerKit` wrapper) with subsystem `com.iblocker`.
    Domain names appear only in `debug` messages. `IBlockerKit` still builds
    and tests on Linux.

Build:

15. `cd ios && xcodegen generate && xcodebuild build -project IBlocker.xcodeproj -scheme IBlocker -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`
    succeeds.

On device (manual, by the user):

16. With the alternative off, the Dashboard shows "Network DNS".
17. With the alternative set to Cloudflare, the Dashboard shows "Cloudflare".
18. With a custom DoH URL `https://192.0.2.1/dns-query` (unreachable),
    browsing still works. After a few lookups, the Dashboard shows "Network
    DNS — Custom unreachable, retrying". After switching to Cloudflare it
    shows "Cloudflare".
19. A router admin page (e.g. `fritz.box` on a Fritz!Box network) or a
    `.local` name resolves with the alternative on.

## Scope

**In scope:** items 1–8.

**Out of scope:**
- DNS cache (KI-9). Large answers and TCP (KI-2).
- New protocols (DoT, DoQ, DNSCrypt) or new provider presets.
- "System encrypted DNS" (`DNSSettingsView`) and the profile export.
- Any third-party DNS library.

## Pending Decisions

- **Retry timings** (3 failures, 2 s timeout, 30 s to 300 s backoff) are
  starting values. Revisit after use.
- **Probe target** `apple.com A`. Change it if it's ever blocked by a list.
