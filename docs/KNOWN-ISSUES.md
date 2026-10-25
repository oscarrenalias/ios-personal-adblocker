# Known issues

Findings from a full read of the iOS code on 2026-10-25, after importing it
from upstream. Nothing here has been confirmed on a device yet unless the
entry says so.

Work through these one at a time. When one is fixed, tick it, add the commit
or spec, and keep the entry for reference.

Severity: **High** affects whether the phone works day to day.
**Medium** is a real bug or cost, but not urgent. **Low** is a design limit
worth knowing.

## Suggested order

1. [ ] [KI-1](#ki-1-no-fallback-when-the-dns-resolver-is-unreachable) Resolver fallback and captive Wi-Fi
2. [ ] [KI-2](#ki-2-lookups-with-large-answers-fail) Large DNS answers
3. [ ] [KI-3](#ki-3-apple-relay-handling-is-switched-off-docs-say-otherwise) Apple relay: test on device, then fix code or docs
4. [ ] [KI-4](#ki-4-tunnel-wakes-up-every-2-seconds) Battery: 2-second wake-ups
5. [ ] [KI-5](#ki-5-background-list-refresh-probably-never-runs) Background refresh
6. [ ] [KI-6](#ki-6-list-exceptions-cant-unblock-subdomains) List exceptions
7. [ ] [KI-7](#ki-7-pause-and-unblock-take-up-to-5-minutes) Pause/unblock delay (small, fix alongside others)

---

## High

### KI-1: No fallback when the DNS resolver is unreachable

- **Status:** specs written, in two parts:
  1. [`spec-4cb10c45`](../specs/done/network-dns-as-the-default-resolver.md):
     network DNS as the default. **Done and verified on device on 2026-10-25.**
  2. [`spec-c7e3c45d`](../specs/planned/alternative-resolver-with-failover-to-network-dns.md):
     alternative resolver with failover. Plan it only after part 1 is
     verified on device.
- **Severity note:** real but rare in practice. Lockdown has the same
  weakness (one Cloudflare DoH server, no fallback) and works fine day to day.
  It's kept first because the fix also adds network DNS as the default.
- **Where:** `ios/IBlockerKit/Sources/IBlockerKit/Engine/DNSProxyEngine.swift`
  (`forward`), `ios/IBlockerKit/Sources/IBlockerTunnelKit/UpstreamFactory.swift`

There is a single upstream resolver (DoH to 1.1.1.1 by default). If it can't
be reached, every lookup returns SERVFAIL and the whole phone loses internet.
This happens on:

- captive-portal Wi-Fi (hotels, airports, cafés), which usually block
  outside DNS until you log in, so the login page never loads
- networks that block 1.1.1.1 or DNS over HTTPS
- a resolver outage

The VPN has an always-on "connect on demand" rule, so it reconnects into the
same broken state. The only way out is turning protection off in the app.

**Fix ideas:** fall back to a second resolver, then to the network's own DNS.
Detect captive portals and let lookups through until the portal is passed.

### KI-2: Lookups with large answers fail

- **Status:** open
- **Where:** `DNSProxyEngine.forward`, `DNSResponseBuilder.truncated`,
  `TunnelConstants.mtu`

If an upstream answer is larger than about 1,470 bytes, the tunnel replies
"truncated" (TC flag). The client then retries over TCP, but the tunnel drops
TCP, so the lookup hangs until it times out. The code comments say this can't
happen, but it can: DNSSEC, large TXT records, HTTPS records with many
addresses.

**Fix ideas:** raise the tunnel MTU and send large answers in full, or send
them as IP fragments. Either way, update the comments.

### KI-3: Apple relay handling is switched off; docs say otherwise

- **Status:** open, needs on-device testing first
- **Where:** `ios/IBlockerKit/Sources/IBlockerKit/Shared/FeatureFlags.swift`
  (`showAppleRelayControls = false`), `SeedRules.relayText`,
  `docs/BLOCKING-MODES.md`

The docs say iOS's "Limit IP Address Tracking" sends tracker traffic through
Apple's relay, where on-device DNS can't see it, and that the default blocks
the relay. In the code, relay blocking is off and hidden. The "block domains"
strategy is the effective default but blocks nothing.

Separately, with iCloud Private Relay on, Safari does its DNS through Apple's
relay, so Safari browsing skips the VPN filter entirely. Only the Safari
content blocker applies.

**Next step:** with "Limit IP Address Tracking" on, check whether in-app ads
load and whether ad domains show as allowed or missing in the log. Then
either turn the relay handling back on or correct `BLOCKING-MODES.md`.

---

## Medium

### KI-4: Tunnel wakes up every 2 seconds

- **Status:** open
- **Where:** `ios/PacketTunnel/PacketTunnelProvider.swift` (`startMaintenance`),
  `DNSProxyEngine.flush`

The maintenance loop runs every 2 seconds, even when idle. Each tick it:

- rewrites `stats.json`
- re-reads shared settings
- every 5th tick, re-opens the blocklist file

This polling probably drains the battery. Not measured yet.

**Fix ideas:** only write stats when they've changed, flush less often, and
react to events (app IPC messages, Darwin notifications) instead of polling.

### KI-5: Background list refresh probably never runs

- **Status:** open, likely but not confirmed
- **Where:** `ios/App/Info.plist`,
  `ios/IBlockerKit/Sources/IBlockerUI/System/ListRefreshScheduler.swift`

`BGAppRefreshTask` needs `UIBackgroundModes` → `fetch` in the app's
Info.plist, and that entry is missing. The scheduling error is hidden by
`try?`. In practice, lists only update when the app is opened and they're
more than 24 hours old (`FilterListsViewModel`).

**Fix ideas:** add the background mode and log scheduling errors.

### KI-6: List exceptions can't unblock subdomains

- **Status:** open
- **Where:** `ios/IBlockerKit/Sources/IBlockerKit/Lists/BlocklistCompiler.swift`
  (`blockHashes.subtract(listAllowHashes)`), `DomainMatcher.verdict`

A list exception like `@@||safe.example.com^` only removes that exact entry.
If the list also blocks `example.com`, then `safe.example.com` stays blocked.
This over-blocks with lists that rely on exceptions, like the AdGuard DNS
filter. OISD is less affected.

**Fix ideas:** compile list exceptions into their own file and check them in
the matcher at lookup time, the same way the user allowlist is checked.

### KI-7: Pause and unblock take up to 5 minutes

- **Status:** open
- **Where:** `DNSProxyEngine.Configuration.blockTTL` (300)

Blocked answers tell iOS to cache them for 300 seconds. After a pause, or
after adding a site to the allowlist, iOS keeps using the cached "blocked"
answer for up to 5 minutes.

**Fix ideas:** use a short cache time for blocked answers (0–10 s).

### KI-8: Query log is a detailed browsing history

- **Status:** open, decision needed
- **Where:** `SharedSettings.queryLogEnabled` (default `true`),
  `QueryLogRing.defaultCapacity` (65,536)

The log is on by default and keeps about 65,000 recent domains on the phone.
That's fine for personal use, but it should be a conscious choice.

**Options:** keep as is, make it smaller, or turn it off by default.

---

## Low: design limits

### KI-9: No DNS cache in the tunnel

Every non-blocked lookup goes to the resolver. iOS caches too, so the effect
is moderate. Adding a small cache would make lookups faster and save battery.

### KI-10: CNAME cloaking isn't caught

The tunnel never looks inside answers, so a tracker hidden behind an allowed
domain via a CNAME gets through.

### KI-11: The blocklist only stores hashes

Domains are stored as 64-bit hashes, so the app can't show which list blocked
a domain. `QueryLogRecord.listId` is reserved for this but always 0.
Accidental hash collisions are negligible.

### KI-12: The riskiest parts have no tests

The 88 package tests cover the DNS engine well. VPN setup, routing and
NetworkExtension behaviour have no tests and can only be checked on a device.

### KI-13: Swift data-race checking is mostly off

Swift 5 language mode, `SWIFT_STRICT_CONCURRENCY = minimal`, and several
`@unchecked Sendable` types. That's not wrong today, but the compiler won't
catch new concurrency mistakes.

### KI-14: `sources.json` has two uncoordinated writers

The app (`FilterListsViewModel`) and the background refresh
(`ListRefreshScheduler`) can both load, modify and save `sources.json`, with
nothing coordinating them. Unlikely to cause problems, but not safe.

### KI-15: `.local` lookups through Network DNS time out after 3 s

- **Status:** open. Found on device on 2026-10-25 (pymobiledevice3 capture).
- **Where:** `ios/IBlockerKit/Sources/IBlockerTunnelKit/NetworkDNSUpstream.swift`

On network changes, iOS sends a unicast `SOA` query for `local` through the
tunnel (6 times in a 3-minute capture). `DNSServiceQueryRecord` treats
`.local` as multicast DNS, so the query never gets a unicast answer. It times
out after 3 s and the client gets SERVFAIL. Each one holds an in-flight slot
for 3 s. Browsing isn't affected, and real `.local` names resolve over mDNS
outside the tunnel.

**Fix ideas:** answer `local` and `*.local` immediately with NXDOMAIN instead
of forwarding them. One caveat: corporate networks that use `.local` in
unicast DNS (Active Directory) wouldn't resolve those names through the tunnel
either way. Decide before changing. Spec B
(`alternative-resolver-with-failover-to-network-dns`) currently lists `local`
as a network-only name, which would keep the timeout.

### KI-16: After a reboot the tunnel ran with 17 rules and default settings

- **Status:** fixed by defects `B-0d1e113d` and `B-28826355` (merged
  2026-10-25, `9ca38b0`). **Confirmed on device on 2026-10-25:** after a
  reboot the tunnel was up before unlock with 233,817 rules and recovered its
  settings 46 s later, at unlock. 24 lookups were blocked and none failed.
- **Found:** on device on 2026-10-25, from a log archive.

iOS starts the on-demand tunnel before the first unlock, when App Group data
is still protected. The tunnel couldn't read the compiled blocklist (only the
17 bundled rules applied) or the shared settings (defaults applied). It never
logged a recovery, and the Dashboard showed the compiled file's count instead
of the live count.

**Fix:**
- Compiled blobs (hashes only) are written without file protection.
- The tunnel retries settings and rules on every maintenance tick until both
  load, and logs `recovered after N s`.
- Load errors are logged.
- The Dashboard shows the live count, or "Tunnel not reachable", and never
  the file's count.
