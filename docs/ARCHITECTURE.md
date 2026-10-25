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
consecutive failures trip it to `down`. Probes (`A apple.com`, 2 s timeout,
NOERROR is success) are allowed after 30 s, then the wait doubles per failed
probe (60, 120, 240) up to 300 s. A successful probe returns to healthy, and
the next trip starts at 30 s again. There are no timers: a probe only starts
when a query that would have used the alternative arrives, or on a network
change, so an idle phone isn't woken (KI-4). Each trip and reset bumps a
generation counter, and results from older generations are ignored.

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
FNV-1a hashes of every domain. The tunnel maps it read-only
(`Data(contentsOf:options:.alwaysMapped)`) and binary-searches the mapped
pages. 800k domains ≈ 6.4 MB of *file*, of which only touched pages are
resident — the extension idles around a few MB.

Matching walks the query name's suffixes (`a.b.c.com` → `a.b.c.com`,
`b.c.com`, `c.com`) and probes user-allow → user-deny → blocklist, so an
entry blocks its whole subtree and a user allow always wins.

## Data flow between app and tunnel

Everything shared lives in the App Group container:

| File | Writer | Reader |
|---|---|---|
| `blocklist.bin`, `allowlist.bin`, `denylist.bin` | app (compiler) | tunnel (mmap) |
| `querylog.ring` (4 MB fixed ring, 64 B records) | tunnel | app (1 Hz tail) |
| `stats.json` | tunnel (2 s cadence) | app (fallback when tunnel unreachable) |
| `sources.json` | app (via `FilterListStore`) | app |
| `contentblocker.json` | app | Safari extension |
| shared `UserDefaults` | app | tunnel (resolver settings, log toggle) |

Control channel: `sendProviderMessage` with JSON-coded `TunnelRequest`
(`reloadRules`, `getStats`, `setResolverSettings`, `ping`). Fallback: the tunnel
polls the blocklist generation number every 10 s, so rule updates land even
if the app is killed before the IPC message.

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
