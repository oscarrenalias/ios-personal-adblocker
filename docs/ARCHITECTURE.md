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
  response by `DNSResponseBuilder`. DoH and UDP upstreams remain as
  user-selectable alternatives.
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
- **TC never set** on synthesized answers → clients never retry over TCP →
  not serving TCP:53 is safe. With a DoH upstream, upstream
  truncation is impossible too.

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
| `sources.json` | app | app |
| `contentblocker.json` | app | Safari extension |
| shared `UserDefaults` | app | tunnel (upstream config, log toggle) |

Control channel: `sendProviderMessage` with JSON-coded `TunnelRequest`
(`reloadRules`, `getStats`, `setUpstream`, `ping`). Fallback: the tunnel
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
raw IP packet out — runs under `swift test` on Linux/macOS:
craft a real DNS query packet, hand it to `DNSProxyEngine`, assert the
reply parses, checksums validate, and the verdict/log/stats are right.
The provider class itself is a thin shell (settings + read loop + IPC
dispatch) verified by the unsigned `xcodebuild` in CI and on-device.
