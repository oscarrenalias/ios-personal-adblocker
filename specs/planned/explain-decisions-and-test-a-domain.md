---
name: Explain decisions and test a domain
id: spec-68c21e18
description: "Attribute each DNS decision to its rule and source, fix list exceptions (KI-6), show details in the log and a test-a-domain screen"
dependencies: null
priority: high
complexity: null
status: planned
tags:
- rules
- query-log
- ui
- ki-6
scope:
  in: null
  out: null
feature_root_id: B-b8755e63
---
# Explain decisions and test a domain

## Objective

Show **why** each DNS lookup was blocked or allowed:
- which rule matched (for example, `ads.example.com` blocked by the rule
  `example.com`);
- which source it came from (a filter list by name, your allowlist or
  denylist, a list exception, or the built-in rules);
- for allowed lookups, which resolver path answered and whether the answer
  came from the cache.

Then let the user type any domain and see the same explanation without a
network lookup.

The work also fixes two known issues:
- **KI-6:** list exceptions (`@@||safe.example.com^`) will unblock
  subdomains, and will override parent-domain blocks from lists.
- **KI-11:** the blocklist stores only hashes, so it can't say which list
  blocked a domain. The compiled blob will now record the source of each
  entry.

Roadmap items "Explain each decision" and "Rule testing"
(`docs/ROADMAP.md`). The rule-testing **preview** of list changes is out of
scope (see Scope).

## Today

- `BlocklistCompiler.compile` (`Lists/BlocklistCompiler.swift`) merges every
  enabled list into one set of FNV-1a hashes. It subtracts the list `@@`
  exceptions by exact hash only, which is KI-6. It writes three blobs in the
  `IBK1` v1 format (`Rules/CompiledBlocklist.swift`):
  - `blocklistURL`
  - `userAllowlistURL`
  - `userDenylistURL`

  The format is sorted u64 hashes and carries no source information.
- `DomainMatcher.verdict(for:)` (`Rules/DomainMatcher.swift`) checks, in
  order: user allow > user deny > built-in > blocklist. It tries every suffix
  with at least two labels, and returns `allow`, `block` or `none` only.
- `QueryLogRecord` (`Log/QueryLogRecord.swift`) is 64 bytes. `listId` (byte
  11) is always 0, and `flags` (13) and the 2 reserved bytes (14–15) are
  unused.
- `ResolverRouter` already knows the route of each query. It logs it as
  `rule=` with one of these values:
  - `alternative`
  - `alternative-off`
  - `network-only`
  - `fallback`
  - `failing`
  - `local-nxdomain`

  The engine doesn't receive that route.
- In `QueryLogView`, each row has a context menu for allow/deny actions.
  There's no detail view.

## Changes

### 1. Stable source numbers

Add `sourceNumbers: [String: UInt8]?` to `FilterListState`. It's optional,
so older saved state still decodes.

- The compiler gives each list source id a number from 1 to 250 the first
  time it compiles that source.
- A number is never reused, even after the source is removed. That way query
  log entries keep pointing at the right list across recompiles.
- If the numbers run out, new sources get `0`, which means unknown. Log this
  at error.

### 2. Compiled format v2 (with attribution)

`CompiledBlocklist` gains format version 2. v1 stays readable.

```
offset 0   magic "IBK1"
offset 4   format version u32 LE (= 2)
offset 8   entry count u32 LE
offset 12  generation u32 LE
offset 16  reserved, 16 zero bytes
offset 32  count × u64 LE hashes, ascending
then       count × u8 source numbers, same order as the hashes
```

- A hash that is in several lists stores the number of the **first** enabled
  source in `state.sources` order.
- `CompiledBlocklistView` reads both versions:
  - `contains(_:)` is unchanged.
  - A new `sourceNumber(of hash:) -> UInt8?` returns the stored number. It
    returns `0` for a v1 blob, and nil when the hash is absent.
  - Lookups still never load the whole set into memory (mmap and binary
    search, as today).
- The compiler writes v2 for the blocklist and for the new exceptions blob
  (section 3). The user allow and deny blobs can stay v1: their source is
  implied.
- `CompiledBlocklistView.init` accepts versions 1 and 2. It validates the
  file size: `32 + count*8` for v1, `32 + count*9` for v2. It exposes
  `formatVersion`.
- Add `lookup(_ hash:) -> UInt8?` (nil means absent; otherwise the source
  number, 0 for v1). It does one binary search and replaces separate
  `contains` and `sourceNumber` calls on the hot path.
- **Rollback** (accepted risk): an older build that reads a v2 blob throws
  `unsupportedVersion`, and the tunnel falls back to the built-in floor until
  that build recompiles. No mitigation.

**Recompile on update:**
- Add `compiledFormatVersion: UInt32?` to `FilterListState`. The compiler
  sets it.
- `FilterListsViewModel.ensureFreshCompile` (around line 175) also
  recompiles when
  `state.compiledFormatVersion != CompiledBlocklist.formatVersion`.
- So the first launch after the update produces v2 blobs and the exceptions
  blob, without waiting for a list refresh.

### 3. List exceptions at lookup time (KI-6)

- The compiler writes list `@@` exception domains to a new blob,
  `AppGroupPaths.listAllowlistURL` (`listallow.bin`, v2, with source numbers).
- It **stops** subtracting exceptions from `blockHashes`. Stats keep
  reporting `listAllowEntryCount`.
- `AppGroupPaths.loadMatcherReportingFailures` loads the new blob with the
  others, for both the tunnel and the app. `AppGroupPaths.relaxBlobProtection`
  includes `listallow.bin`, so a tunnel started before the first unlock can
  read it.
- A missing exceptions file means no exceptions. That covers the first run
  after the update, before the recompile. A file that exists but fails to
  load is a load failure, reported like the others.
- **Write order:** write `listallow.bin`, `userallow`, `userdeny`, then
  `blocklist.bin` **last**, then post the signal. The tunnel's generation
  check reads `blocklist.bin`, so it can't see the new generation before the
  exceptions are on disk.
- When loading, the tunnel accepts the exceptions blob only if its generation
  equals the blocklist's. On a mismatch, it keeps the current matcher and
  retries on the next check. Unit test.

New matcher precedence:

1. user allowlist → allow
2. user denylist → block
3. built-in rules → block. The built-in floor ignores list exceptions.
4. list exception: any suffix of the name matches → allow, and list blocks
   don't apply
5. blocklist → block
6. nothing matched → none (allowed, forwarded)

So `@@||safe.example.com^` now allows `safe.example.com` and
`x.safe.example.com`, even when a list blocks `example.com`. The exception
still has no effect on the user denylist or the built-in rules.

### 4. Matcher explanation

Add to `DomainMatcher`:

```swift
public enum MatchSource: Equatable, Sendable {
    case userAllowlist, userDenylist, builtIn
    case listException(sourceNumber: UInt8)   // 0 = unknown list
    case list(sourceNumber: UInt8)            // 0 = unknown list
}
public struct Match: Equatable, Sendable {
    public let source: MatchSource
    public let matchedSuffix: String          // e.g. "example.com"
}
public struct Explanation: Equatable, Sendable {
    public let verdict: Verdict
    public let decidingMatch: Match?          // nil when verdict == .none
}
public func explain(_ domain: String) -> Explanation
/// Every match in every set, for the test screen (precedence order).
public func allMatches(for domain: String) -> [Match]
```

- `verdict(for:)` must return exactly `explain(_:).verdict`. Implement both
  with the same lookup.
- The tunnel's hot path (`DNSProxyEngine.handlePacket`) calls `explain` once
  per query in place of `verdict`.
- Internally, the match records the label count of the matched suffix.
  `matchedSuffix` is built lazily, or only in `allMatches`, so blocked
  queries don't allocate a new string.
- Cost: at most one extra binary search per suffix when the exceptions blob
  is non-empty, and none otherwise.
- Within each set, the most specific suffix wins, as today.

### 5. Resolver route reported to the engine

- `ResolverRouter` exposes the route it used for each resolved query, through
  a new method such as `resolveWithRoute(_:) async throws -> (Data,
  UpstreamRoute)`. The agent picks the exact shape.
- Fixed mapping from the router's log `rule` to `UpstreamRoute`:

  | Router rule | `UpstreamRoute` |
  |---|---|
  | `alternative` | `.alternative` |
  | `alternative-off` | `.network` |
  | `network-only` | `.networkOnlyName` |
  | `fallback`, and `failing` that then goes to network DNS | `.fallback` |
  | `local-nxdomain` | `.local` (synthetic NXDOMAIN) |

- Other `DNSUpstream` implementations report `.network`.
- **Failures:** when the router throws, it throws `RoutedError { route,
  underlying }`, so a failed query can record its route. For example,
  `failing` under the "Never fall back" policy records `.alternative`.
  Failures from the in-flight limit never reach the upstream and record route
  0 (unknown).

### 6. Query log record v2 fields

The record stays 64 bytes, and only reserved bytes are used:

| Byte | Field |
|---|---|
| 11 `source` | 0 = not recorded (old record), 1 = no rule matched (also non-IN class queries, which skip the matcher), 2 = user allowlist, 3 = user denylist, 4 = built-in, 5 = list exception, 6 = list, 7 = blocking paused (matcher not consulted) |
| 13 `flags` | bit 0 = answered from cache; bits 1–3 = route (0 unknown, 1 alternative, 2 network, 3 network-only name, 4 fallback, 5 local); bit 7 = "details present" (set by this version) |
| 14 `sourceNumber` | list source number for sources 5/6, else 0 |
| 15 `matchedLabels` | label count of the matched suffix (`example.com` = 2), 0 if none |

- The matched suffix is rebuilt from the domain's last `matchedLabels`
  labels. Domains longer than 48 bytes are stored as their suffix today, so
  the matched suffix still survives.
- Records without bit 7 decode as "no details".
- Blocked queries have route 0 and cache 0.
- Cache hits have cache 1 and route 0. `DNSCache` entries don't store the
  route, and the UI shows only "Answered from cache".
- Failed queries record the route from `RoutedError`, or 0.
- `DNSProxyEngine` fills these for the blocked, cache-hit, allowed and failed
  paths.

### 7. Log entry details (UI)

Tapping a row in `QueryLogView` opens a detail sheet. The existing context
menu stays. The sheet shows the domain, time, query type, verdict, and a
**Why** line:

- Blocked: "Blocked by `example.com` in OISD Big", or "… by your denylist" or
  "… by built-in rules".
- Allowed by rule: "Allowed by `safe.example.com` (exception in AdGuard DNS
  filter)", or "… by your allowlist".
- Allowed, no rule: "No rule matched".
- Allowed while paused: "Allowed: blocking was paused".
- For allowed lookups, a second line: "Answered from cache", or the route:
  - "Encrypted DNS"
  - "Network DNS"
  - "Network DNS (name always sent to your network)"
  - "Network DNS (encrypted resolver unavailable)"
  - "Answered locally (.local name)"

  The record doesn't store which resolver answered. The line therefore never
  names one, so it can't go stale after a resolver change.
- Failed: "Lookup failed" plus the route line when known.
- Old records: "Details not recorded for this entry".

Source numbers resolve to list names through `FilterListState` (sources and
`sourceNumbers`). A removed list shows as "a removed list". The sheet also
offers the same Allow/Block actions as the context menu.

Put the text in a pure presentation type, `DecisionExplanationPresentation`,
so it can be unit-tested.

### 8. Test a domain (UI)

Add a "Test a domain" screen, linked from the Lists tab (toolbar or a row at
the top).

- The user types a domain. The input is normalized with `DomainValidator`;
  invalid input shows a message.
- The app builds a `DomainMatcher` with
  `paths.loadMatcherReportingFailures(builtInBlockHashes:
  SeedRules.fallbackHashes(state:))`. Those are the same blobs and the same
  built-in floor the tunnel uses, respecting hidden and disabled bundled
  sources. It shows:
  - the verdict and Why line, using the same presentation as section 7;
  - every match from `allMatches`, each with its source name and matched
    suffix. Overridden matches are marked, for example "also listed in
    HaGeZi Pro (overridden by your allowlist)".
- List matches whose source is a bundled source (`bundled-core`,
  `bundled-apple-relay`) are folded into the built-in match. They don't show
  as a separate overridden list.
- No DNS lookup and no network access.
- If the compiled files are missing or still v1, it says "Rules are being
  rebuilt" and offers a recompile.

## Logging

Follow `docs/LOGGING.md`. Domains appear only at debug.

- `lists`, **info**: after a compile, `compiled v2: <n> blocked, <m> list exceptions, <k> sources numbered`.
- `lists`, **error**: `source numbers exhausted, <id> recorded as unknown`.
- `engine`, **debug**: extend the existing per-query blocked/allowed lines
  with `source=<kind>[#n] suffix=<matched>` and, for allowed lookups,
  `route=<route> cache=<bool>`.
- `tunnel`, **notice**: `blocklist v1 loaded (no attribution); waiting for recompile`
  when a v1 blob is loaded. Log it once per load.
- `ui`, **debug**: `explain opened` (with domain) and `test domain` (with
  domain and verdict).
- `ui`, **info**: `test domain: recompile requested` when the user asks for a
  recompile from the test screen.
- `lists`, **notice**: `recompiling: compiled format <old> → <new>` when the
  format check triggers a recompile at launch.
- `tunnel`, **error**: the existing blob-load failure line covers
  `listallow.bin`. **notice**: `list exceptions generation <a> ≠ blocklist <b>, deferring reload`.

## Acceptance Criteria

1. **Exceptions (KI-6):** with a list blocking `example.com` and an
   exception `@@||safe.example.com^`, `safe.example.com` and
   `a.safe.example.com` are allowed and `ads.example.com` is blocked. A user
   denylist entry or a built-in rule still blocks despite the exception.
   Unit tests.
2. **Explanation:** `explain` returns the deciding source and matched suffix
   for each precedence level, and `verdict(for:)` always equals
   `explain(_:).verdict`. Unit tests, including a property-style test over
   mixed sets.
3. **Format:** a v2 blob round-trips hashes and source numbers.
   `CompiledBlocklistView` still reads v1 blobs and reports source 0. A hash
   in two lists gets the first source's number. Unit tests.
4. **Stable numbers:** a source keeps its number across recompiles, and a
   removed source's number is never reused. Unit tests.
5. **Log record:** a v2 record round-trips every new field. An old record
   (bit 7 clear) decodes with "no details". Unit tests.
6. **Engine:** for each case below, the record carries the right source,
   route and cache flag. Unit tests with stub upstreams.
   - blocked;
   - cache-hit (cache 1, route 0);
   - allowed via `.alternative`, `.network` and `.fallback`;
   - failed via `RoutedError`;
   - failed at the in-flight limit (route 0);
   - paused (source 7);
   - non-IN class (source 1).
6a. **Upgrade:** a state with `compiledFormatVersion` nil and v1 blobs
   recompiles to v2, plus `listallow.bin`, on `ensureFreshCompile`, without a
   list refresh. Unit test.
6b. **Load safety:** the exceptions blob is written before `blocklist.bin`.
   A mismatched exceptions generation defers the reload. Unit tests.
7. **Presentation:** `DecisionExplanationPresentation` produces each Why line
   listed in section 7, including "a removed list" and "Details not recorded
   for this entry". Unit tests.
8. **Test a domain:** on device, typing a domain blocked by a list shows the
   list's name and the matched suffix. A domain on the user allowlist that is
   also in a list shows both matches, with the list match marked overridden.
   No network traffic is made.
9. **Log details:** on device, tapping a blocked and an allowed entry in the
   Log tab shows the Why line and, for the allowed one, the resolver or cache
   line.
10. **Performance:** the tunnel's per-query cost doesn't change measurably. A
    benchmark-style unit test runs `explain` over 100k names against a 400k
    entry v2 blob. With an empty exceptions blob it stays within 1.2× of
    today's `verdict` timing on the same blob size, and with 10k exceptions
    within 2×.
11. **Logging:** the lines in the Logging section appear at the listed levels.
    Check with unit tests where practical, and on device in Console.app with
    verbose logging on.
12. **Docs:**
    - `docs/KNOWN-ISSUES.md`: KI-6 and KI-11 marked fixed.
    - `docs/ARCHITECTURE.md`: v2 format and precedence.
    - `docs/ROADMAP.md`: both items done, preview listed as a follow-up.

## Scope

**In:** source numbering, the v2 blob format, the list exceptions blob and
the new precedence, matcher explanation, the resolver route, the log record
fields, the log detail sheet, the test-a-domain screen, and docs.

**Out:**
- **Preview** of list changes (compiling a changed selection in memory and
  diffing it). This is a follow-up spec.
- Storing which **other** lists also contain a blocked hash in the blob. Only
  the first source is stored, and the test screen finds the rest at runtime
  by checking each set. The blob merges lists, so the test screen can only
  report the first source per set. It doesn't re-parse cached list text.
- CNAME cloaking (KI-10).
- Changes to the content blocker (Safari) rules.
- The query log on-by-default decision (KI-8).

**Accepted side effect:** exceptions are no longer subtracted at compile
time, so "Active rules" (`blockedEntryCount`) rises by the number of
exactly-excepted entries. That's usually a handful. The count is still
truthful, because those entries are in the blob and overridden at lookup.

## Files to Add/Modify (hints)

| File | Change |
|---|---|
| `ios/IBlockerKit/Sources/IBlockerKit/Lists/FilterListSource.swift` | `sourceNumbers` in state |
| `ios/IBlockerKit/Sources/IBlockerKit/Lists/BlocklistCompiler.swift` | numbering, v2 writes, exceptions blob, no subtraction |
| `ios/IBlockerKit/Sources/IBlockerKit/Rules/CompiledBlocklist.swift`, `CompiledBlocklistView.swift` | v2 format, `sourceNumber(of:)` |
| `ios/IBlockerKit/Sources/IBlockerKit/Rules/DomainMatcher.swift` | exceptions set, precedence, `explain`, `allMatches` |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/AppGroupPaths.swift` | `listAllowlistURL`, `loadMatcherReportingFailures`, `relaxBlobProtection` |
| `ios/IBlockerKit/Sources/IBlockerUI/Lists/FilterListsViewModel.swift` | format-version recompile trigger |
| `ios/IBlockerKit/Sources/IBlockerKit/Rules/SeedRules.swift` | (read only) `fallbackHashes`, bundled source ids |
| `ios/IBlockerKit/Sources/IBlockerKit/Engine/ResolverRouter.swift`, `DNSUpstream.swift` | route reporting |
| `ios/IBlockerKit/Sources/IBlockerKit/Engine/DNSProxyEngine.swift` | explain on hot path, record fields |
| `ios/IBlockerKit/Sources/IBlockerKit/Log/QueryLogRecord.swift` | new fields |
| `ios/PacketTunnel/PacketTunnelProvider.swift` | generation-match check for the exceptions blob |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/DecisionExplanationPresentation.swift` | new |
| `ios/IBlockerKit/Sources/IBlockerUI/Log/QueryLogView.swift` (+ new detail view) | detail sheet |
| `ios/IBlockerKit/Sources/IBlockerUI/Lists/TestDomainView.swift` (new), `FilterListsView.swift` | test screen and entry point |
| `docs/KNOWN-ISSUES.md`, `docs/ARCHITECTURE.md`, `docs/ROADMAP.md` | docs |
