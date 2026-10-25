---
name: Network DNS as the default resolver
id: spec-4cb10c45
description: "Add a Network DNS upstream (DNSServiceQueryRecord bound to the physical interface) and make it the default; KI-1 part 1, also the on-device feasibility check"
dependencies: null
priority: high
complexity: null
status: done
tags:
- dns
- tunnel
- resilience
scope:
  in: null
  out: null
feature_root_id: B-2cfc79f4
---
# Network DNS as the default resolver

## Objective

Add a "Network DNS" upstream that answers non-blocked lookups using the
current network's own DNS servers (what the phone would use without the app),
and make it the default for new installs.

This is part 1 of 2 for `docs/KNOWN-ISSUES.md` KI-1. Part 2, "Alternative
resolver with failover to network DNS", builds on it and is planned only after
this spec is verified on a device.

## Problems to Fix

- The tunnel can only forward to a fixed DoH or UDP resolver.
  `UpstreamConfig.Kind` has `.doh` and `.udp`, and `UpstreamConfig.default`
  is `https://1.1.1.1/dns-query`
  (`ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelIPC.swift`). There's no
  way to use the network's own DNS. That rules out the fallback path part 2
  needs, and differs from comparable apps (AdGuard), which use network DNS by
  default.

## Background and decisions

- **Own engine, no third-party DNS library.** DnsLibs and dnscrypt-proxy were
  evaluated and rejected for now. Do not add a DNS library dependency.
- **Mechanism (taken from AdGuard's design):** resolve with
  `DNSServiceQueryRecord` (`dns_sd.h`, public API), passing the **interface
  index of the physical network interface**. iOS then answers using that
  interface's DNS configuration instead of the tunnel's, so there's no loop
  back into the tunnel and no need to know the DNS server IPs. AdGuard for iOS
  is GPLv3: read it for the design only and do not copy code. Reference:
  AdguardTeam/DnsLibs (Apache-2.0) `upstream/system_resolver_apple.cpp`.
- **Rejected:** reading server IPs with `res_9_getservers` while the tunnel is
  up returns the tunnel's own DNS address.
- **This spec is also the feasibility check.** Whether interface-bound
  resolution works inside *our* split tunnel is the main risk for KI-1. It is
  confirmed on a device (acceptance criteria 9–12) before part 2 is planned.

## Changes

### 1. Build responses from resolved records (pure logic)

Extend the existing `DNSResponseBuilder`
(`ios/IBlockerKit/Sources/IBlockerKit/DNS/DNSResponseBuilder.swift`) with a
function that builds a full response from a parsed `DNSQuery`, a result code,
and a list of resource records (owner name, type, class, TTL, raw RDATA in
wire format).

- Header: the query's transaction ID, QR=1, RD copied from the query, RA=1,
  AA=0, TC=0. QDCOUNT=1, ANCOUNT = the number of records, NSCOUNT=0,
  ARCOUNT=0.
- Question: `query.rawQuestion` copied byte-exactly (keeps 0x20 casing).
- Answers: in the order given. CNAME records come before the records they
  point to.
- Result codes: NOERROR with records; NOERROR with no records (NODATA);
  NXDOMAIN with no records. No SOA in the authority section, and no EDNS OPT
  record.
- The size check stays in the engine. `DNSProxyEngine.forward` already
  compares the answer size against the MTU; don't change that.

### 2. Network DNS upstream

A new `DNSUpstream` in `ios/IBlockerKit/Sources/IBlockerTunnelKit/` that
resolves through `DNSServiceQueryRecord`, bound to an interface index it gets
from an injected provider.

- Parses the incoming message with `DNSParser.parseQuery`. If that fails
  (responses, multi-question or exotic messages), it throws, and the engine
  drops those messages as it does today for unparseable messages that fail
  upstream.
- Queries the question's name, type and class. It collects every answer
  record, including CNAMEs returned as intermediates, until the query
  completes, then builds the reply with item 1.
- Result mapping: records → NOERROR. `kDNSServiceErr_NoSuchName` → NXDOMAIN.
  `kDNSServiceErr_NoSuchRecord` → NODATA. Any other error → the upstream
  throws, and the engine answers SERVFAIL as today.
- Timeout: **3 s**. On timeout it throws.
- If the provider has no interface, it throws immediately.

### 3. Picking the interface

In the tunnel extension (`ios/PacketTunnel/PacketTunnelProvider.swift`), an
`NWPathMonitor` tracks the current path and supplies the interface to the
network upstream:

- Use the first entry of `path.availableInterfaces` whose type is `.wifi`,
  `.cellular` or `.wiredEthernet`. The tunnel's own interface (type `.other`)
  is never used.
- Update it on every path change, so Wi-Fi ↔ cellular switches take effect
  without restarting the tunnel.
- If no such interface exists, the upstream throws, which gives SERVFAIL.

### 4. Configuration and defaults

- Add `.network` to `UpstreamConfig.Kind`. `UpstreamConfig.default` becomes
  `.network`. `displayName` for `.network` is `"Network DNS"`.
- `UpstreamFactory.make` builds the network upstream for `.network`.
- There's no migration: an existing stored `upstreamConfig` keeps being used.
  Only installs with nothing stored get network DNS.
- Settings: add **"Network DNS (default)"** as the first entry of
  `SettingsView.upstreamChoices`
  (`ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift`). Change
  the section footer to explain that network DNS uses the current Wi-Fi or
  cellular network's resolver, and that the other choices send lookups to a
  specific provider.
- Switching to or from Network DNS uses the existing `setUpstream` IPC path.
  No tunnel restart.

### 5. Docs

- Update `README.md` ("How it works", "Privacy") and `docs/ARCHITECTURE.md`
  (packet path diagram, "No recursion" note) for network DNS as the default.

## Files to Modify

| File | Change |
|---|---|
| `ios/IBlockerKit/Sources/IBlockerKit/DNS/DNSResponseBuilder.swift` | Build responses from records (item 1) |
| `ios/IBlockerKit/Sources/IBlockerTunnelKit/` (new file) | Network DNS upstream (item 2) |
| `ios/IBlockerKit/Sources/IBlockerTunnelKit/UpstreamFactory.swift` | `.network` case (item 4) |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelIPC.swift` | `.network` kind, new default, display name (item 4) |
| `ios/PacketTunnel/PacketTunnelProvider.swift` | `NWPathMonitor` and interface provider (item 3) |
| `ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift` | New first choice and footer (item 4) |
| `ios/IBlockerKit/Tests/IBlockerKitTests/` | Tests for items 1 and 4 |
| `README.md`, `docs/ARCHITECTURE.md` | Docs (item 5) |

## Acceptance Criteria

Automated (`swift test --package-path ios/IBlockerKit`):

1. For a query and a list of records, decoding the new builder's output
   (header fields read directly in the test; `DNSParser.parseQuery` rejects
   responses) shows: the same ID, QR=1, RD equal
   to the query's, RA=1, AA=0, TC=0, QDCOUNT=1, ANCOUNT equal to the number
   of records, NSCOUNT=0, ARCOUNT=0, and a question section byte-identical to
   `query.rawQuestion` (tested with a mixed-case name).
2. A CNAME followed by an A record is emitted in that order, and each
   record's RDATA is copied byte-exactly.
3. NXDOMAIN gives RCODE 3 with ANCOUNT 0. NODATA gives RCODE 0 with
   ANCOUNT 0.
4. `UpstreamConfig.default.kind == .network`, and its `displayName` is
   `"Network DNS"`. A stored DoH config still decodes and is returned
   unchanged (`SharedSettingsTests`).
5. A stored `.network` config round-trips through `SharedSettings` and
   through `TunnelIPCCoder` (`setUpstream`).
6. All existing tests pass.

Build (an agent can run this):

7. `cd ios && xcodegen generate && xcodebuild build -project IBlocker.xcodeproj -scheme IBlocker -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`
   succeeds.

Code review:

8. The network upstream never sends a query to `TunnelConstants.dnsIPv4` or
   `dnsIPv6`, and passes a non-zero physical interface index to
   `DNSServiceQueryRecord`.

On device (manual, by the user, after merge; gates planning of part 2):

9. With Network DNS selected, browsing works and lookups appear in the Log as
   allowed or blocked.
10. Each lookup is answered once. No repeated or looping queries for the same
    name show in the Log within a second.
11. Switching Wi-Fi ↔ cellular keeps DNS working without restarting
    protection.
12. Switching between Network DNS and Cloudflare (DoH) in Settings takes
    effect without restarting protection.
13. The events listed in the Logging section are logged at the stated levels,
    and no domain name is logged above `debug`.

## Logging

Per [docs/LOGGING.md](../../docs/LOGGING.md). Subsystem `com.iblocker`.

| Category | Level | Event |
|---|---|---|
| `tunnel` | `notice` | tunnel up (rule count, upstream name), tunnel stopping, `setUpstream` applied |
| `tunnel` | `error` | invalid upstream config at start, `setUpstream` failed (kind, reason) |
| `path` | `info` | selected interface changed (old → new, path status) |
| `path` | `notice` | no usable physical interface (path status, interface types) |
| `engine` | `info` | rules reloaded (blocked entry count, generation), upstream switched |
| `engine` | `debug` | per-query verdict (blocked, allowed with duration, failed with SERVFAIL), truncated or dropped oversize answers, in-flight limit hits |
| `network-dns` | `debug` | query start (interface index), complete (rcode, record and CNAME counts, duration), failed, timed out, rejected, `dns_sd` errors |

Domain names appear only at `debug`.

## Scope

**In scope:** items 1–5.

**Out of scope:**
- The alternative resolver toggle, failover, circuit breaker, name-based
  routing and status display (part 2).
- DNS cache (KI-9). Large answers and TCP (KI-2).
- Any third-party DNS library.

## Pending Decisions

- **If criteria 9–10 fail on device** (a loop, empty answers or timeouts),
  stop and report back. Don't try other mechanisms without a decision.
- **The `kDNSServiceErr_NoSuchName` / `NoSuchRecord` mapping** is from
  Apple's `dns_sd.h`. If a device shows NXDOMAIN and NODATA both arrive as
  the same error, map both to NXDOMAIN and note it in the PR.
