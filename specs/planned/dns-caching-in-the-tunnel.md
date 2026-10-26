---
name: DNS caching in the tunnel
id: spec-697234a9
description: "Bounded TTL-respecting DNS cache in the tunnel (KI-9), 10 s blocked TTL (KI-7), cache stats and Clear button in Settings, stats write-skip (part of KI-4)"
dependencies: null
priority: high
complexity: null
status: planned
tags:
- dns
- tunnel
- performance
scope:
  in: null
  out: null
feature_root_id: B-f5b41847
---
# DNS caching in the tunnel

## Objective

The tunnel answers repeat lookups of allowed names from a bounded in-memory
cache that respects DNS TTLs. Lookups get faster, especially over encrypted
DNS, and fewer go out to the resolver. The same spec shortens the TTL of
blocked answers, so pausing or allowing a site takes effect within seconds.

This is `docs/ROADMAP.md` item 3 (DNS caching). It fixes
`docs/KNOWN-ISSUES.md` KI-9 (no cache) and KI-7 (blocked TTL 300 s). It
also covers the cheap part of KI-4: no stats rewrite when nothing changed.

## Where the cache sits

In `DNSProxyEngine.handlePacket`
(`ios/IBlockerKit/Sources/IBlockerKit/Engine/DNSProxyEngine.swift`). The
cache lookup goes after the block check and **before `forward`'s in-flight
guard**. Hits never count toward `inFlight`, and are never SERVFAILed under
load. Misses go through `forward` as today and are stored after
`upstream.resolve` returns.

```
packet → parse → blocked? → (blocked answer, never cached)
                         → cache hit?  → cached answer, rewritten for this query
                         → cache miss  → upstream → maybe store → answer
```

Because the cache comes after the block check, blocked names are never served
from it. So rule reloads, allow/deny changes and pause don't need to clear it:
- While paused, real answers for normally blocked names may be cached. After
  the pause ends, the block check runs first again.
- A newly allowed name was never in the cache.

## Behaviour

### What is cached

- Only parsed queries (`DNSParser.parseQuery` succeeded) with `qclass == 1`
  (IN). Unparseable messages are forwarded untouched, as today.
- **Key:** the query's `rawQuestion` bytes (wire-form name plus qtype and
  qclass), ASCII-lowercased, plus a flag for "query carries EDNS"
  (`DNSQuery.hasAdditionalRecords`).
  - Wire form avoids the dotted-name ambiguity, where the single label
    `a.b` and the two labels `a`,`b` would otherwise collide.
  - It also guarantees the replacement question on a hit is the same length,
    so compression pointers stay valid.
  - Because of the EDNS flag, an answer that carries an OPT record is never
    served to a query that sent no OPT (RFC 6891), and vice versa.
- **Bypass the cache entirely** (no lookup, no store) when:
  - the query sets CD (header flag `0x0010`), or
  - the query's OPT record sets the DO bit.

  These are DNSSEC-aware clients. Don't assume iOS never sends them.
- **A stored response's question must match the query's.** Compare the
  bytes case-insensitively. Otherwise it isn't cached.
- **Positive answers** (NOERROR with at least one answer record): TTL is the
  minimum TTL across the answer section, CNAME chain included.
- **Negative answers:**
  - Covers NXDOMAIN, and NOERROR with no answer records (NODATA).
  - TTL is the SOA's MINIMUM field or the SOA record's TTL, whichever is
    lower, from the authority section (RFC 2308), capped at 300 s.
  - If there's no SOA, use a fixed 30 s. This explicitly includes
    `NetworkDNSUpstream`'s synthesized NXDOMAIN/NODATA and the router's local
    `.local` NXDOMAIN (`DNSResponseBuilder.nxdomain`).
- **TTL bounds:**
  - Positive TTLs are capped at 1 hour.
  - A computed TTL of 0 means don't cache.
- **Never cached:**
  - SERVFAIL, REFUSED or any other rcode
  - responses with TC set
  - responses whose question doesn't match the query (name, type, class)
  - unparseable responses
  - answers bigger than 4,096 bytes

### Serving a hit

- Copy the stored response and rewrite it for the new query:
  - **Transaction ID:** set to the new query's.
  - **Question section:** replace it with the query's exact `rawQuestion`
    bytes, keeping the DNS 0x20 case.
  - **TTLs:** for every record in the answer, authority and additional
    sections except OPT, set the served TTL to
    `max(1, min(originalRecordTTL, entryTTL) − age)`. `age` is whole seconds
    since the entry was stored. The OPT pseudo-record is left unchanged.
  - **Other flags:** keep the RD bit from the query and the rest of the
    response's flags.
- **Expiry:** an entry expires when `entryTTL − age ≤ 0`. An expired entry
  is a miss. It's removed when found, plus during the periodic purge below.
- **Counting:**
  - A *hit* is a valid, unexpired entry found.
  - A *miss* is a cacheable query (parsed, IN, not blocked, not bypassed)
    with no valid entry.
  - Bypassed and unparseable queries count as neither.
- A hit still goes through the normal path:
  - It's recorded in stats and the query log as allowed.
  - It still uses `packets(for:payload:)`, so large answers are still
    IP-fragmented.

### Limits

- At most **2,000 entries** and **1 MB of stored response bytes**, whichever
  is hit first.
- Evict the least recently used entry when either limit would be exceeded.
- Expired entries are purged opportunistically. Either do it on insert, or on
  the existing maintenance tick, at most once every 60 s.
- The tunnel extension has about 50 MB, so these limits must hold.

### Invalidation

**Late answers after a clear.** The engine is a reentrant actor, so a
lookup can be in flight while the cache is cleared. When that lookup returns,
its answer comes from the old resolver or network and must not be stored:
- `DNSCache` keeps a `generation` counter that every `clear()` bumps.
- `forward` captures the generation before `await upstream.resolve`.
- It stores the answer only if the generation is unchanged.

Clear the whole cache when:
- **The resolver changes:** `DNSProxyEngine.setUpstream`, from IPC
  `setResolverSettings` or recovery.
- **The network changes:** the path monitor already calls
  `ResolverRouter.networkChanged()` in `PacketTunnelProvider`. Clear the
  cache at the same point. Answers from network DNS can be specific to that
  network.
  - The handler runs on `pathQueue`, and `engine` is a plain `var`. So keep
    the engine in a `LockedBox`, as `routerBox` does, and call
    `Task { await engine.clearCache(reason: .networkChange) }` from the
    handler.
  - The handler fires once at start and then whenever the selected interface
    changes.
- **The resolver status changes** (`ResolverRouter` `onStatusChange`, any
  transition, for example alternative ↔ fallingBack). Otherwise answers
  fetched over unencrypted network DNS during a fallback would keep being
  served for up to an hour after encrypted DNS recovers.
- **The user taps "Clear DNS cache"** (below).
- **The tunnel stops.** The cache is in memory only.

### Blocked-answer TTL (KI-7)

- `DNSProxyEngine.Configuration.blockTTL` default goes from 300 to **10**
  seconds. The blocked answers themselves don't change.

### Stats, IPC and UI

- **`TunnelRuntimeStats`** (`ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelIPC.swift`)
  gains optional `UInt64?` fields:
  - `cacheEntries`
  - `cacheHits`
  - `cacheMisses`, counted since the tunnel started

  Decode them with `decodeIfPresent`, so an older app/tunnel pair still
  decodes.
- **New IPC request `clearDNSCache`**, answered with `.ok`. The request must
  be appended to the enum without breaking decoding of the existing cases.
- **Settings** (`SettingsView.swift`, inside or right after the "Upstream
  DNS (VPN mode)" section) gets a "Cache" row. It's gated on
  `tunnel.state == .connected` and `tunnel.runtimeStats`, the same way
  `resolverStatusPresentation` is. It refreshes in the existing
  `refreshLoop()`.
  - **Not** `DNSSettingsView`, which is the System DNS (no-VPN) screen.
  - The row text comes from a pure presentation type, like
    `ResolverStatusPresentation`:
    - "N entries · X% hit rate", with X = hits / (hits + misses), rounded
      down
    - "N entries · no lookups yet" when hits + misses = 0
    - "Not available" when the tunnel isn't connected or the fields are nil
  - Below it is a **"Clear DNS cache"** button. It calls a new
    `TunnelController.clearDNSCache()`, which sends the request and then
    calls `refreshStats()`. If the reply is nil (an older tunnel) or
    `.failure`, the row shows "Not available" and the failure is logged at
    error.
  - Footer text: "Clears the ad blocker's cache. iOS keeps its own short-lived
    cache."

### Stats write (cheap part of KI-4)

- `DNSProxyEngine.flush` writes `stats.json` only if `stats` (which is
  `Equatable`) differs from the last written snapshot. That snapshot starts
  as the loaded `BlockerStats`. This applies to every `flush()` caller. The
  query log flush is unchanged.
- The 2 s maintenance interval and polling stay as they are. The rest of KI-4
  is out of scope.

## Acceptance Criteria

1. A `DNSCache` type in IBlockerKit (pure, injected clock) stores and serves
   answers per the rules above. Unit tests cover:
   - positive TTL taken from the minimum answer TTL, including through a
     CNAME chain
   - negative TTL from the SOA, capped at 300 s
   - the no-SOA negative fallback of 30 s
   - TTL 0 not cached
   - SERVFAIL, TC and question-mismatch responses not cached
   - expiry
   - remaining-TTL rewrite in all sections, with OPT untouched
   - transaction ID and question (0x20 case) rewrite
   - LRU eviction by entry count, and by byte limit
   - `clear()`
   - wire-form key with case folding
   - an EDNS query and a plain query using separate entries
   - CD/DO bypass
   - question mismatch rejected
   - the generation counter
2. `DNSProxyEngine` uses the cache:
   - Engine tests with a fake upstream show a second identical query isn't
     sent upstream and returns a correctly rewritten answer.
   - A blocked name is never served from the cache.
   - `setUpstream` clears the cache.
   - A late answer is not cached. Test this with a fake upstream that
     suspends while `setUpstream` or `clearCache` runs mid-flight.
   - A hit is served while `inFlight` is at its limit.
   - Hit and miss counters appear in `statsSnapshot`.
3. `PacketTunnelProvider`:
   - clears the cache on network change (engine held in a `LockedBox`) and
     on resolver status change
   - handles IPC `clearDNSCache`
   - passes the cache counters through `getStats`
4. `blockTTL` defaults to 10 s, and the existing tests are updated.
5. The `TunnelRuntimeStats` additions and `clearDNSCache` round-trip through
   `TunnelIPCCoder`. Old payloads without the new fields still decode
   (unit test).
6. The cache-row presentation type is unit-tested:
   - nil stats or disconnected → "Not available"
   - zero lookups → "no lookups yet"
   - percentages rounded down

   `SettingsView` shows the row and the Clear button as described.
7. `flush` skips the stats write when the counters haven't changed (unit
   test with a temp stats URL).
8. `docs/KNOWN-ISSUES.md` marks KI-9 and KI-7 fixed and notes KI-4 as
   partly addressed. `docs/ROADMAP.md` marks item 3 done (pending device
   check). `docs/ARCHITECTURE.md` describes the cache.
9. `swift test --package-path ios/IBlockerKit` passes, and the iOS app builds
   (CI).
10. The events in the Logging section are logged at the stated levels.
11. **Manual (on device, by the user):**
    - Browsing works normally.
    - The Settings ▸ DNS cache row shows a rising hit rate.
    - "Clear DNS cache" resets the entry count.
    - After pausing, a blocked site loads within about 10 s.

## Logging

Per [docs/LOGGING.md](../../docs/LOGGING.md): subsystem
`net.renalias.adblocker`, category `cache` (new, add it to the categories
list). Domain names appear only at debug, per the existing rule.

| Event | Level | Example |
|---|---|---|
| Cache cleared (with reason: resolver change, resolver status change, network change, user, and entries dropped) | notice | `cache cleared (network change): 412 entries` |
| Periodic summary, at most once every 10 minutes and only if there was traffic | info | `cache: 1203 entries, 712 KB, hit rate 64% (hits 5120, misses 2880), evicted 37` |
| Eviction because a limit was hit (aggregated, at most once a minute) | info | `cache evicted 25 entries (byte limit)` |
| Hit / miss / store / not-cacheable (with reason) for a name | debug | `hit example.com AAAA, ttl left 212 s` / `not cached example.com A: SERVFAIL` |
| IPC `clearDNSCache` received | info (category `tunnel`) | `IPC clearDNSCache` |
| Late answer not stored (generation changed) | debug | `not cached example.com A: cache cleared while in flight` |
| App: `clearDNSCache` failed / no reply | error (category `ipc`) | `clearDNSCache failed: no reply (older tunnel?)` |

## Scope

**In:**
- the cache and its tests
- engine and tunnel integration
- invalidation
- the blocked TTL change
- stats, IPC and the Settings row
- the stats write-skip
- docs

**Out:**
- serve-stale and prefetching
- coalescing identical in-flight queries
- caching unparseable or multi-question messages
- persisting the cache across tunnel restarts
- the "answered from cache" mark in the query log (ROADMAP item 4 will use
  the record's reserved bytes)
- the rest of KI-4 (polling interval, event-driven reloads)

## Files to Add/Modify (hints)

- **New:** `ios/IBlockerKit/Sources/IBlockerKit/Engine/DNSCache.swift`, plus
  a small response-record walker if needed (it must skip compressed names).
  `ios/IBlockerKit/Sources/IBlockerKit/DNS/DNSName.swift` has the name
  codec.
- `ios/IBlockerKit/Sources/IBlockerKit/Engine/DNSProxyEngine.swift`
- `ios/IBlockerKit/Sources/IBlockerKit/Shared/TunnelIPC.swift`
- `ios/PacketTunnel/PacketTunnelProvider.swift`
- `ios/IBlockerKit/Sources/IBlockerUI/Settings/SettingsView.swift` and
  `ios/IBlockerKit/Sources/IBlockerUI/System/TunnelController.swift`
  (`clearDNSCache()`). Put the new presentation type in
  `ios/IBlockerKit/Sources/IBlockerKit/Shared/`.
- **Tests:** a new `DNSCacheTests.swift`, plus additions to the engine and
  IPC tests in `ios/IBlockerKit/Tests/IBlockerKitTests/`.
- `docs/KNOWN-ISSUES.md`, `docs/ROADMAP.md`, `docs/ARCHITECTURE.md`,
  `docs/LOGGING.md`.
