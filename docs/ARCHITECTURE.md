# Architecture

## The packet path (VPN mode)

```
┌─────────────── iPhone ────────────────────────────────────────────┐
│                                                                   │
│  Any app ──DNS query──► iOS resolver ──► utun (198.18.0.2:53)     │
│                                             │                     │
│                              PacketTunnel extension               │
│                              ┌──────────────▼───────────────┐     │
│                              │ PacketParser (IPv4/v6 + UDP) │     │
│                              │ DNSParser (wire format)      │     │
│                              │ DomainMatcher ◄── mmap'd     │     │
│                              │   │        blocklist.bin     │     │
│                       blocked│   │allowed                   │     │
│                              ▼   ▼                          │     │
│                    DNSResponseBuilder   Upstream            ─┼──► internet
│                    (0.0.0.0 / :: /      (Network DNS default, │    (physical
│                     NODATA)             or DoH/UDP)          │     interface)
│                              │   │                           │     │
│                              └───┴──► UDPReplyBuilder ──► utun ──► app
│                              └──────────────────────────────┘     │
└───────────────────────────────────────────────────────────────────┘
```

Key decisions:

- **Split tunnel**: `includedRoutes` contains only `198.18.0.2/32` and
  `fd00::2/128`. All real traffic (HTTP, video, games) never touches the
  tunnel — zero throughput cost, minimal battery cost. `NEDNSSettings` with
  `matchDomains = [""]` makes those fake resolvers the system default.
- **Network DNS is the default upstream**: `NetworkDNSUpstream` resolves
  allowed queries with `DNSServiceQueryRecord`, bound to the physical
  interface index supplied by an `NWPathMonitor` in `PacketTunnelProvider`.
  The system resolver on that interface answers with whatever DNS the current
  Wi-Fi/cellular network hands out, and the result is rebuilt into a wire
  response by `DNSResponseBuilder`. DoH and UDP upstreams are available as an
  optional alternative resolver (see
  [Resolver router and failover](#resolver-router-and-failover)).
- **No recursion**: interface-bound `DNSServiceQueryRecord` lookups leave via
  the physical interface and never re-enter the tunnel. The tunnel's own DNS
  addresses (`TunnelConstants.dnsIPv4`/`dnsIPv6`) are never used as the
  upstream. If no usable interface is available the query fails rather than
  falling back. For DoH/UDP upstreams, sockets target addresses outside the
  included routes so they also exit over the physical interface; those
  endpoints are IP literals because the extension's hostname lookups would
  otherwise loop back into the tunnel it serves.
- **HTTPS/SVCB answered**: type-65 queries carry `ipv4hint`/`ipv6hint` —
  a blocker that only answers A/AAAA leaks through modern Safari. Blocked
  domains get NODATA for every non-A/AAAA qtype.
- **0x20 preserved**: responses echo the question section byte-exactly, so
  resolvers using case-randomization accept our answers.
- **TC is not set on synthesized answers**, and large upstream answers are
  IP-fragmented (RFC 791 / 8200) rather than truncated, because the tunnel
  does not serve TCP:53. TC is only a last resort for answers above the
  maximum UDP datagram size (65,507 bytes IPv4 / 65,527 IPv6).

## Resolver router and failover

`DNSProxyEngine` holds one `DNSUpstream` and doesn't know about failover. That
upstream is a `ResolverRouter` (`Engine/ResolverRouter.swift`) wrapping the
network upstream and the optional alternative. Blocking happens in the engine,
before the router. Rules, in order:

1. `local` and `*.local` (any type) get NXDOMAIN from
   `DNSResponseBuilder.nxdomain(for:)`. Nothing is forwarded, no probe starts.
   `.local` device names resolve over mDNS outside the tunnel, and answering
   iOS's `SOA local` lookup at once avoids the 3 s Network DNS timeout (KI-15).
   Networks that serve `.local` over unicast DNS (Active Directory) aren't
   resolved through the tunnel.
2. Alternative off: everything goes to network DNS.
3. Network-only names (`NetworkOnlyNames`: `lan`, `home.arpa`, private reverse
   zones, Wi-Fi calling and router setup names) always go to network DNS under
   both policies and never trigger probes.
4. Alternative on and healthy: ask the alternative with a 2 s timeout enforced
   by the router. The deadline holds even if the upstream ignores task
   cancellation: the router returns at 2 s and drops any late result. On
   failure or timeout, count a failure and apply the
   **fallback policy**: `.networkDNS` re-sends the same query to network DNS;
   `.none` throws, so the engine answers SERVFAIL.
5. Alternative down: skip it. `.networkDNS` goes to network DNS, `.none`
   throws. If a probe is due, one starts in the background.

**Circuit breaker** (`Engine/CircuitBreaker.swift`, injected clock). Three
consecutive failures trip it to `down`. A failure counts only if its request
started at or after the last counted failure, so queries stalled together on
one connection count as one. Probes (`A apple.com`, 2 s timeout,
NOERROR is success) are allowed after 5 s, then the wait doubles per failed
probe (10, 20, 40) up to 300 s. A successful probe returns to healthy, and
the next trip starts at 5 s again. There are no timers: a probe only starts
when a query that would have used the alternative arrives, or on a network
change, so an idle phone isn't woken (KI-4). Each trip and reset bumps a
generation counter, and results from older generations are ignored.

**Connection reset.** When an alternative query fails or times out, when the
breaker trips, and when a probe times out, the router calls
`resetConnection(reason:)` on the alternative's upstream, at most once per
2 s. `DoHUpstream` swaps its `URLSession` for a fresh one, so the next query
opens a new connection instead of reusing a stalled one. Other upstreams
ignore the call.

The `resolver status old -> new` notice log reports `encrypted yes/no` from
the new status itself (`.alternative(_, encrypted)`), not from the current
alternative setting, so a transition to `networkDNS` or `down` logs `no`.

**Network change.** `PacketTunnelProvider` calls `router.networkChanged()` only
when the selected physical interface changes. The breaker resets to healthy and
one probe runs at once; a single failed probe doesn't re-trip it.

**Status.** `router.status` is a `ResolverStatus`: `network`,
`alternative(name:encrypted:)`, `fallingBack(name:)` or `failing(name:)`.
`getStats` copies it into `TunnelRuntimeStats.resolverStatus` (nil from older
tunnels). Only DoH counts as encrypted (`UpstreamConfig.isEncrypted`).

**Settings.** `ResolverSettings` (`useAlternative`, `alternative`,
`alternativeName`, `fallbackPolicy`) is stored as JSON under `resolverSettings`
in shared defaults. If it's missing, it's derived on read from the old
`upstreamConfig` without writing (DoH/UDP becomes an enabled alternative with
`.networkDNS`; missing or network becomes off). The app sends
`setResolverSettings` over IPC and the tunnel rebuilds the router, which
resets breaker state. Presets live in `UpstreamPreset`: seven, in order Cloudflare (DoH),
Cloudflare (malware blocking, `1.1.1.2`), Cloudflare (family, `1.1.1.3`),
AdGuard DNS, Quad9 (DoH, `https://9.9.9.9/dns-query`, port 443), Cloudflare
(UDP) and Quad9 (UDP). Port 5053 timed out on a home network, so Quad9 uses
443; the system encrypted-DNS preset (`DNSProviderPreset.quad9.tunnelDoHURL`)
matches. On read, a stored DoH alternative of `https://9.9.9.9:5053/dns-query`
is replaced in memory by the Quad9 preset config and name (nothing is written
back; other URLs are untouched) and logged once per process. At boot, until
settings are readable, the router runs with defaults and is rebuilt on recovery.

## DNS cache

`DNSProxyEngine` owns a `DNSCache` (an actor-confined struct, not
thread-safe). Order for each query: blocked names are answered first (with
`blockTTL`, 10 s), then the cache, then the resolver. Blocked answers are never
cached, so rule and pause changes apply immediately to blocked lookups.

- **Key:** the question (name lowercased, type, class) plus whether the query
  carried EDNS. Only IN queries qualify; CD and the DO bit bypass the cache.
- **TTL:** the lowest record TTL in the answer, capped at 3600 s. Negative
  answers use the SOA minimum, capped at 300 s. TTL 0 isn't stored.
- **Hits:** the stored response is rewritten for the new query (ID, exact question
  case, RD bit) and record TTLs count down with the entry's age (minimum 1).
- **Limits:** 2,000 entries and 1 MB, with LRU eviction; expired entries are
  purged every 60 s.
- **Clearing:** on resolver change, resolver status change, network change,
  and the user's "Clear DNS cache" action (IPC `clearDNSCache`).
  Each clear bumps a generation counter, so a lookup that started before the
  clear isn't stored when it returns.
- **Stats:** entry count, hits and misses go into the tunnel stats for the
  Settings cache row.

## List update pipeline

`FilterListStore` (`IBlockerKit/Lists`) is an actor and the only owner of
load/modify/save of the list state (`sources.json`), so the app, the
background refresh, the Shortcuts intent and the Lists screen can't lose each
other's updates (KI-14). Callers use `updateAll(force:trigger:)`, `mutate` and
`compile`. A call that arrives during a run awaits it instead of downloading
again.

For each enabled list, `FilterListUpdater` does a conditional GET (ETag /
Last-Modified), writes the body to a temp file, and runs
`FilterListValidator` on it. The validator rejects HTML pages, empty lists, lists where
more than 50% of non-comment lines don't parse, and lists with fewer than 50%
of the previous entry count. A rejected download is discarded and its reason
is stored as the list's `lastRejection`, so the last good copy stays in use.
An accepted one replaces the cached copy atomically (`replaceItemAt`), then
the store recompiles the blobs if anything changed. `force` only bypasses the
conditional-GET shortcut for lists that already have a cached file.

`ListFreshness` flags a list as stale when its last accepted update is more
than 7 days old. The Lists screen shows the age, a Stale badge and the
rejection reason.

Updates start from four triggers (logged): the user, the stale check at app
launch, the Shortcuts intent, and `ListRefreshScheduler`, which submits a
`BGAppRefreshTask` (earliest 6 h out; needs `UIBackgroundModes` → `fetch`).
Everything logs under category `lists`.

## Memory (the 50 MB extension budget)

The compiled blocklist is a flat file: 32-byte header + sorted `u64`
FNV-1a hashes of every domain (plus one source byte per hash in v2, see
below). The tunnel maps it read-only
(`Data(contentsOf:options:.alwaysMapped)`) and binary-searches the mapped
pages. 800k domains ≈ 6.4 MB of *file*, of which only touched pages are
resident — the extension idles around a few MB.

Matching walks the query name's suffixes (`a.b.c.com` → `a.b.c.com`,
`b.c.com`, `c.com`) and probes the sets in precedence order (below), so an
entry blocks its whole subtree and a user allow always wins.

### Compiled blobs and precedence

Format (`CompiledBlocklist`): magic `IBK1`, version, entry count, generation,
then sorted hashes. **v1** (`allowlist.bin`, `denylist.bin`) is hashes only.
**v2** (`blocklist.bin`, `listallow.bin`) appends one `u8` source number per
hash, in hash order. If a hash is in several lists, the first source wins.
`CompiledBlocklistView` reads both versions and can return the source number
for a hash.

Source numbers (1–250) identify list sources. They're allocated by the
compiler, kept stable in `FilterListState.sourceNumbers` (`sources.json`), and
resolved to list names in the app. 0 means unknown (for example, numbers
exhausted). `FilterListState.compiledFormatVersion` records the format last
compiled; when it differs from the current one, the app recompiles. Until the
tunnel sees a v2 blocklist with a matching `listallow.bin` generation it
defers the reload; a v1 blocklist is loaded without attribution.

`DomainMatcher` precedence, highest first:

1. user allowlist
2. user denylist
3. built-in rules
4. list exceptions (`@@`, `listallow.bin`), matched at any suffix; they
   override list blocks but not the user or built-in sets
5. compiled blocklist

`DomainMatcher.explain` returns the verdict, the deciding set and the number
of labels of the matching suffix (the rule text is rebuilt from the query);
`allMatches` lists every hit in every set, used by "Test a domain".

### Decision explanations

Each query log record (64 bytes) keeps the verdict, a decision source byte
(none, user allow, user deny, built-in, list exception, list, paused) and,
when flag bit 7 is set, v2 details: cache hit, route (alternative, network,
network-only name, fallback, local), source number and matched label count.
Older records without details still decode. The query log detail sheet and
the "Test a domain" screen (Lists) present these through
`DecisionExplanationPresentation`; no domain strings are added to the blobs.

## Data flow between app and tunnel

Everything shared lives in the App Group container:

| File | Writer | Reader |
|---|---|---|
| `blocklist.bin`, `listallow.bin`, `allowlist.bin`, `denylist.bin` | app (compiler) | tunnel (mmap) |
| `querylog.ring` (4 MB fixed ring, 64 B records) | tunnel | app (1 Hz tail while a log or chart view is visible) |
| `stats.json` | tunnel (flushed on each maintenance timer pass: 60 s idle, 2 s degraded) | app (fallback when tunnel unreachable) |
| `sources.json` | app (via `FilterListStore`) | app |
| `contentblocker.json` | app | Safari extension |
| shared `UserDefaults` | app | tunnel (resolver settings, log toggle) |

Control channel: `sendProviderMessage` with JSON-coded `TunnelRequest`
(`reloadRules`, `getStats`, `setResolverSettings`, `clearDNSCache`, `flushLog`, `ping`). While a
log or chart view is visible, the app sends `flushLog` before each 1 Hz ring
read so recent records are in the ring.

**Maintenance loop.** The tunnel has no fixed 2 s loop. One task
(`startMaintenance`, planned by `Shared/MaintenanceSchedule.swift`) sleeps until
the next timer deadline or a Darwin signal (`Shared/TunnelSignal.swift`),
then runs one pass; signals that arrive during a pass coalesce into one
follow-up pass.

- Timer passes: every 60 s when idle (flush, re-read settings, blocklist
  generation check); every 2 s while degraded (adds recovery retries; the
  blocklist check runs every 5th tick).
- `settingsChanged` (posted by `SharedSettings` on writes): runs the settings
  step (pause deadline, verbose flag) and recovery if degraded.
- `blocklistChanged` (posted by `BlocklistCompiler` after a compile): runs the
  blocklist generation check. This replaces the old 10 s poll, so rule
  updates land even if the app is killed before the IPC message; the 60 s
  timer pass is the backstop if a signal is missed.
- A pending verbose-logging expiry shortens the next wake to just past the
  expiry. Changing between degraded and idle recomputes the deadline.

### Widget encryption line

The status widget shows whether DNS is encrypted and which resolver answers.
The widget extension can't ask the tunnel, so the tunnel mirrors the
router's status into shared `UserDefaults` (`SharedSettings.widgetResolverStatus`,
JSON-coded `ResolverStatus`).

- **Publish.** `PacketTunnelProvider.publishWidgetStatus` writes the status
  on tunnel start and on every router status change, including when a new
  router replaces the old one.
- **Gate.** `WidgetReloadGate` reduces the status to what the widget shows
  (`WidgetEncryptionPresentation.State` plus resolver name). The tunnel
  reloads the widget timeline (`WidgetCenter.reloadTimelines`) only when
  that pair differs from the last published one, so status churn that
  doesn't change the visible line costs no reload. The write, gate decision
  and reload run under one lock so concurrent publishes can't interleave.
- **Start and stop.** Start reloads unconditionally after publishing. Stop
  clears the value, resets the gate and reloads unconditionally.
- **Read.** `StatusWidget.makeEntry` reads the mirror together with
  `protectionActive` and `pausedUntil` and builds a
  `WidgetEncryptionPresentation` for the layouts.
- **Known limitation: stale state.** The mirror is cleared only by
  `stopTunnel`. If the tunnel dies without running it (crash, jetsam),
  the last value stays in the shared defaults and the widget can keep
  showing it. `TunnelController.syncStatus` is the backstop: when the app
  sees the VPN as `disconnected` or `invalid` it clears the value and reloads
  the widgets. Until the app runs and observes that, the line can be stale.

## Notifications

Status notifications tell the user when protection changes while the app is
closed. They are off until the user turns them on in Settings, which is also
when the system permission prompt appears.

**Policy.** `StatusNotificationPolicy.decide(event:state:preferences:now:)`
(`Shared/StatusNotificationPolicy.swift`) is a pure function: an event, the
persisted state, the master switch and per-type toggles, and the clock go in;
actions (`schedule`, `cancel`, `postRestore`), the new state, suppression
reasons and a debug trace come out. Eight kinds exist: resolver fallback,
resolver failing, protection stopped, restored, list rejected, list stale,
pause ended and degraded (built-in rules only). `NotificationPoster` carries
out the actions and is the only code that touches `UNUserNotificationCenter`.

**Episodes.** Kinds 1, 2, 3 and 7 are problems with an episode
(`NotificationEpisodeState`: open, scheduled fire time, notified). A repeat
while an episode is open is ignored. A restore is posted only when the
problem was actually delivered, and it reuses the problem's identifier so it
replaces that notification. Switching between fallback and failing ends the
other episode silently. `stopTunnel` ends pending 1, 2, 6 and 7 silently.

**Debounce through pending triggers.** A problem is not delayed by a timer
in the tunnel, since the extension can be killed. It is scheduled as a
`UNTimeIntervalNotificationTrigger` request (30 s for resolver problems,
60 s for protection stopped, 5 min for degraded). If the problem clears
first, the pending request is removed and nothing is shown; otherwise the
system delivers it even if the extension is gone. "Delivered" is inferred
from the fire time having passed with the request not removed.

**Rate limit.** At most one notification per kind within 5 minutes. A rate
limited problem still opens its episode, so no restore follows a
notification the user never saw. Episodes and fire times live in the shared
`UserDefaults`, so the app and the tunnel see the same state.

**User-off marker.** The app, the Control Center control and the widget set
`SharedSettings.userTurnedOff` when the user turns protection off, and clear
it when they turn it on. On a stop, `classifyStop` treats a set marker, or a
`userInitiated` / `appUpdate` reason, as expected and stays quiet; any other
stop (including `superceded`, which is another VPN taking over) raises
"protection stopped".

**Who posts.**
- The tunnel (`PacketTunnelProvider.StatusNotifier`, an actor so
  load-decide-save of the shared state never interleaves) handles resolver
  status changes, unexpected stops, restores, pause deadlines and degraded
  starts.
- The app handles blocklist events (rejected, stale) in `FilterListStore`
  and, as a fallback for a tunnel that died without running `stopTunnel`,
  the "tunnel gone" check in `ListRefreshScheduler` on background refresh.
- Taps go to the app's `UNUserNotificationCenterDelegate`
  (`IBlockerApp.swift`), which routes to Dashboard or Lists using the
  `tab` field in `userInfo`.

**Privacy.** Content comes from `StatusNotificationContentBuilder` and never
holds a domain, IP or URL. Only preset resolver names are shown; a custom
resolver becomes "your custom resolver". Built-in lists show their name;
custom lists show the name the user typed, or "a custom blocklist".

## Why the log is a ring file

Bounded disk by construction (no rotation logic inside the memory-limited
extension), O(1) append, torn writes damage at most one 64-byte slot (the
reader validates and skips), and the app tails it by monotonic cursor with
no parsing ambiguity.

## Testing strategy

Everything above the NetworkExtension API boundary is a pure function of
bytes and lives in `ios/IBlockerKit`, so the whole path — raw IP packet in,
raw IP packet out — runs under `swift test` on macOS:
craft a real DNS query packet, hand it to `DNSProxyEngine`, assert the
reply parses, checksums validate, and the verdict/log/stats are right.
The provider class itself is a thin shell (settings + read loop + IPC
dispatch) verified by the unsigned `xcodebuild` in CI and on-device.
