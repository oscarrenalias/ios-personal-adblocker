---
name: Network DNS fallback with optional alternative resolver
id: spec-a5bcca33
description: "Use the network's own DNS by default, with an optional alternative resolver that falls back to network DNS and is retried via a circuit breaker (fixes KI-1)"
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
# Network DNS fallback with optional alternative resolver

## Objective

Lookups that aren't blocked are answered by the current network's own DNS by
default. The user can optionally choose an alternative resolver, which is used
while it is reachable. When it isn't, lookups fall back to the network's DNS
and the alternative is retried periodically until it works again.

## Problems to Fix

This fixes `docs/KNOWN-ISSUES.md` KI-1.

- The tunnel forwards every non-blocked lookup to one fixed resolver
  (`UpstreamConfig.default` = `https://1.1.1.1/dns-query`,
  `ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelIPC.swift`). There is no
  fallback. If that resolver can't be reached, `DNSProxyEngine.forward`
  (`ios/IBlockerKit/Sources/IBlockerKit/Engine/DNSProxyEngine.swift`) returns
  SERVFAIL for every lookup and the phone has no working DNS. Examples: Wi-Fi
  that blocks outside DNS before a captive-portal login, networks that block
  1.1.1.1 or DoH, and resolver outages.
- There is no way to use the network's own DNS (what the phone uses without
  the app). Comparable apps (AdGuard) use it by default.

## Background and decisions

- **Own engine, no third-party DNS library.** DnsLibs (AdGuard, C++) and
  dnscrypt-proxy (Go) were evaluated and rejected for now: they add a large
  native dependency and a heavy build, and neither fits better than extending
  our engine. Do not add a DNS library dependency.
- **Prior art: AdGuard for iOS.** AdGuard for iOS is GPLv3, so read it for the
  design only and do not copy code. It uses the network's DNS through a
  `system://<interface>` upstream. That calls `DNSServiceQueryRecord` with the
  physical interface's index (Wi-Fi `en0`, cellular `pdp_ip0`, taken from
  `NWPathMonitor`), so iOS answers with that interface's DNS configuration
  instead of the tunnel's. This avoids discovering DNS server IPs, and avoids
  a loop back into the tunnel. Relevant AdGuard files:
  `AdGuardSDK/DNS/Utils/NetworkUtils/NetworkUtils.swift`,
  `AdGuardSDK/DNS/PacketTunnelProvider/PacketTunnelProviderProxy.swift`, and
  DnsLibs (Apache-2.0) `upstream/system_resolver_apple.cpp`.
- **Rejected alternative:** reading resolver IPs with `res_9_getservers` while
  the tunnel is up returns the tunnel's own DNS address. AdGuard's legacy path
  works around this by clearing tunnel settings for a second, which is fragile.
- **Retrying differs from AdGuard on purpose.** AdGuard tries the primary
  resolver on every query and falls back per query, so every lookup pays a
  timeout while the primary is down. This spec uses a circuit breaker instead
  (see Changes, item 3).
- **Lockdown** (dnscrypt-proxy, single Cloudflare DoH server) has no fallback
  at all. Its 10-minute minimum cache hides short outages. A DNS cache is a
  separate issue (KI-9) and out of scope here.

## Changes

### 1. Network DNS resolver (new upstream)

Add an upstream that resolves a DNS query through iOS's resolver on the
current physical network interface, so the answer comes from the network's
own DNS servers.

- Takes a raw DNS query and returns a raw DNS response, like the existing
  `DNSUpstream` protocol
  (`ios/IBlockerKit/Sources/IBlockerKit/Engine/DNSUpstream.swift`).
- Bound to a specific interface (by name or index) supplied by the caller.
  It must never send the query through the tunnel's own DNS address.
- Builds a valid DNS response for the original query: the same transaction
  ID, the original question bytes (keep 0x20 casing), and answer records
  including CNAMEs. Map "no such name" to NXDOMAIN and "no records of this
  type" to NOERROR with no answers. Respect the client's message size the way
  the existing engine does.
- Has a timeout. A timeout or error is reported as an upstream failure.
- The part that builds responses from individual records must be pure logic
  inside `IBlockerKit`, so it can be unit-tested without a device.

### 2. Settings: optional alternative resolver

- A new shared setting, **"Use alternative DNS"**, off by default, in
  `SharedSettings`
  (`ios/IBlockerKit/Sources/IBlockerKit/Shared/SharedSettings.swift`).
- When on, the user picks one alternative from the existing choices in
  `SettingsView.upstreamChoices`
  (`ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift`):
  Cloudflare, AdGuard and Quad9 over DoH, Cloudflare and Quad9 over UDP. The
  existing custom DoH and UDP fields stay. Cloudflare DoH is preselected.
- When off, all non-blocked lookups go to the network DNS.
- Changes apply to a running tunnel without restarting it, through the
  existing `setUpstream` IPC path or an extension of it.
- Upgrades: an existing stored `upstreamConfig` becomes the selected
  alternative, and the toggle starts off.

### 3. Failover and circuit breaker

When the alternative resolver is enabled, the tunnel decides where each
non-blocked lookup goes:

- **Healthy:** queries go to the alternative. If one fails or times out, the
  same query is immediately re-sent to the network DNS, so the app making the
  lookup still gets an answer.
- **Down:** after **3 consecutive** failures, mark the alternative as down.
  From then on, queries go straight to the network DNS with no extra delay.
- **Retry:** while it is down, test the alternative in the background with a
  real query, first after **30 s**, then doubling each time up to
  **5 minutes** between tests. The first successful test marks it healthy
  again and queries return to it.
- **Network change:** when the network path changes (Wi-Fi ↔ cellular,
  another Wi-Fi network, connectivity regained), reset the breaker to healthy
  and test the alternative again.
- The timeout for a query to the alternative is **2 s**. That's the
  worst-case extra delay a lookup gets from the alternative failing.
- If the network DNS fails too, return SERVFAIL for that query, as today.
- Blocking is unchanged and happens first. The resolver only answers lookups
  that weren't blocked. Pause behaviour is unchanged.

The breaker must be pure logic with an injectable clock, so it can be
unit-tested.

### 4. Names that always use the network DNS

These names always go to the network DNS, even when the alternative is
healthy, because only the local network or the carrier can answer them
correctly. They are still checked against the blocklist first.

- `local`, `lan`, `home.arpa`, `service.arpa` and their subdomains
- DNS service discovery names (`*._dns-sd._udp.*`)
- reverse lookups for private address ranges: `10.in-addr.arpa`,
  `16.172.in-addr.arpa` to `31.172.in-addr.arpa`, `168.192.in-addr.arpa`,
  `d.f.ip6.arpa`
- Wi-Fi calling (ePDG) names: `*.pub.3gppnetwork.org`, plus the
  carrier-specific ePDG names in DnsLibs' default `fallback_domains` list
  (`proxy/dnsproxy.cpp` in AdguardTeam/DnsLibs). This is a list of domain
  names, not code.

### 5. Tunnel wiring

- The tunnel extension watches the network path with `NWPathMonitor`. It
  passes the current physical interface to the network DNS upstream and
  resets the breaker on changes (item 3).
- If there is no usable physical interface, return SERVFAIL. There's no
  network to answer anyway.

### 6. Showing which resolver is answering

- `TunnelRuntimeStats` reports which resolver is currently in use: network
  DNS, the alternative (by display name), or "network DNS, alternative
  unreachable — retrying".
- The DNS section in Settings and the Dashboard show this in plain language.

### 7. Docs

- Update `README.md` ("How it works", "Privacy") and `docs/ARCHITECTURE.md`
  for the new default and the fallback.
- In `docs/KNOWN-ISSUES.md`, mark KI-1 as fixed and link this spec.

## Files to Modify

| File | Change |
|---|---|
| `ios/IBlockerKit/Sources/IBlockerTunnelKit/` (new file) | Network DNS upstream bound to an interface (item 1, the API calls) |
| `ios/IBlockerKit/Sources/IBlockerKit/DNS/` (new file) | Build DNS response messages from resolved records (item 1, pure logic) |
| `ios/IBlockerKit/Sources/IBlockerKit/Engine/` (new file) | Failover upstream and circuit breaker (item 3) |
| `ios/IBlockerKit/Sources/IBlockerKit/Engine/DNSProxyEngine.swift` | Route by name rules (item 4) and failover |
| `ios/IBlockerKit/Sources/IBlockerTunnelKit/UpstreamFactory.swift` | Build the network, alternative and failover upstreams |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/SharedSettings.swift` | "Use alternative DNS" setting and upgrade handling |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelIPC.swift` | Alternative on/off over IPC, resolver status in `TunnelRuntimeStats` |
| `ios/PacketTunnel/PacketTunnelProvider.swift` | `NWPathMonitor`, interface hand-off, breaker reset |
| `ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift` | Toggle, picker, status line |
| `ios/IBlockerKit/Sources/IBlockerUI/Dashboard/DashboardView.swift` | Resolver status |
| `ios/IBlockerKit/Tests/IBlockerKitTests/` | Tests for the response builder, breaker, routing and engine failover |
| `README.md`, `docs/ARCHITECTURE.md`, `docs/KNOWN-ISSUES.md` | Docs (item 7) |

## Acceptance Criteria

Automated (`swift test --package-path ios/IBlockerKit`, no device needed):

1. With the alternative off, the engine sends non-blocked queries to the
   network upstream only. A test with fake upstreams shows the alternative is
   never called.
2. With the alternative on and healthy, non-blocked queries go to the
   alternative. If the alternative fails or times out on a query, the reply
   for that query comes from the network upstream, and the client gets a
   valid response, not SERVFAIL.
3. After 3 consecutive alternative failures, the next queries go to the
   network upstream without calling the alternative. Tested with an injected
   clock.
4. While the alternative is down, background tests run at 30 s, 60 s, 120 s,
   240 s, then every 300 s. After a successful test, queries go to the
   alternative again. Tested with an injected clock.
5. A network-change event resets the breaker to healthy and triggers a test
   of the alternative.
6. Names in item 4 (e.g. `printer.local`, `1.168.192.in-addr.arpa`,
   `epdg.epc.mnc260.mcc310.pub.3gppnetwork.org`) go to the network upstream
   even when the alternative is healthy, and blocked names in those zones are
   still blocked.
7. Blocking behaviour is unchanged: all existing tests pass, and a blocked
   name never reaches any upstream.
8. The response builder produces a message that `DNSParser` and a strict
   check accept: same ID, QR set, the question bytes copied exactly, correct
   counts, CNAME chains in order, NXDOMAIN and NODATA mapped correctly.
9. If both upstreams fail, the client gets SERVFAIL, as today.
10. The project builds with `xcodegen generate` and a signed `xcodebuild` for
    a device.

On device (manual; record the results in the PR or the bead's notes):

11. With the alternative off, browsing works and lookups appear in the log.
    The Dashboard shows "Network DNS".
12. With the alternative set to an unreachable custom DoH URL (for example
    `https://192.0.2.1/dns-query`), browsing still works. After 3 lookups the
    status shows "alternative unreachable — retrying". After the URL is
    changed to a working one, the status returns to the alternative within
    5 minutes, or straight away after a network change.
13. Switching between Wi-Fi and cellular keeps DNS working without
    restarting the tunnel.
14. A query sent to the network DNS doesn't loop back into the tunnel. Check
    in the log that each lookup is answered once, not repeatedly.

## Scope

**In scope:** everything in Changes 1–7.

**Out of scope:**
- DNS cache in the tunnel (KI-9).
- Large answers, the TC flag and TCP (KI-2).
- New DNS protocols (DoT, DoQ, DNSCrypt) and new provider presets.
- Changes to "System encrypted DNS" (`DNSSettingsView`) or the profile export.
- IPv6-only and DNS64 network handling beyond what the network DNS gives us
  for free. Note any problems found during on-device testing.
- Any third-party DNS library.

## Pending Decisions

- **Interface-bound resolution inside our tunnel:** we assume
  `DNSServiceQueryRecord` with a physical interface index works inside our
  split-tunnel extension without looping back. AdGuard ships this, but its
  tunnel setup differs from ours. If on-device testing shows a loop or empty
  answers, stop and report back before trying alternatives.
- **Retry timings** (3 failures, 30 s to 5 min, 2 s timeout) are starting
  values. Revisit after use if they feel wrong.
