---
name: Fix Quad9 DoH preset and add Cloudflare filtering presets
id: spec-5274afcf
description: "Quad9 DoH preset to port 443 (5053 times out), migrate stored old URL on read, add Cloudflare 1.1.1.2 and 1.1.1.3 presets; depends on spec-c7e3c45d"
dependencies: null
priority: medium
complexity: null
status: planned
tags:
- dns
- presets
scope:
  in: null
  out: null
feature_root_id: B-b602aed6
---
# Fix Quad9 DoH preset and add Cloudflare filtering presets

## Objective

Make the Quad9 DoH preset use the standard HTTPS port, and offer Cloudflare's
malware-blocking (1.1.1.2) and family (1.1.1.3) resolvers as alternative DNS
presets.

**Depends on:** `spec-c7e3c45d` ("Alternative resolver with failover to
network DNS") being merged. It moves the presets into `UpstreamPreset` in
`IBlockerKit` and adds `ResolverSettings` with read-time migration. Don't
plan this spec before then.

## Problems to Fix

- The Quad9 preset uses `https://9.9.9.9:5053/dns-query`. Tested from the
  user's Mac on 2026-10-25, the connection to port 5053 timed out, while
  `https://9.9.9.9/dns-query` (port 443) answered correctly with a valid
  certificate for the IP. Port 443 works on far more networks. The same URL
  is also in `DNSProviderPreset.quad9.tunnelDoHURL`
  (`ios/IBlockerKit/Sources/IBlockerKit/Profile/DNSProviderPreset.swift`).
- The user wants Cloudflare's filtering resolvers as choices. Both work over
  IP-literal DoH with valid certificates (tested 2026-10-25):
  `https://1.1.1.2/dns-query` and `https://1.1.1.3/dns-query`.

## Changes

### 1. Presets (`UpstreamPreset`, added by spec-c7e3c45d)

The final preset list, in this order:

| name | label | config |
|---|---|---|
| Cloudflare | Cloudflare (DoH) | DoH `https://1.1.1.1/dns-query` |
| Cloudflare (malware blocking) | Cloudflare (DoH, malware blocking) | DoH `https://1.1.1.2/dns-query` |
| Cloudflare (family) | Cloudflare (DoH, malware + adult content blocking) | DoH `https://1.1.1.3/dns-query` |
| AdGuard DNS | AdGuard DNS (DoH, extra blocking) | DoH `https://94.140.14.14/dns-query` |
| Quad9 | Quad9 (DoH, malware blocking) | DoH **`https://9.9.9.9/dns-query`** |
| Cloudflare (UDP) | Cloudflare (UDP 53, unencrypted) | UDP `1.1.1.1` |
| Quad9 (UDP) | Quad9 (UDP 53, unencrypted) | UDP `9.9.9.9` |

### 2. Migrate the old Quad9 URL

When `ResolverSettings` is read (stored, or derived from the old
`upstreamConfig`), an alternative whose config is DoH
`https://9.9.9.9:5053/dns-query` is replaced with the new Quad9 preset config,
named "Quad9".
- Like spec-c7e3c45d's migration, this happens on read and doesn't write.
  The corrected value is saved the next time the user changes a DNS setting.
- No other custom URL is changed.

### 3. System encrypted DNS preset

Change `DNSProviderPreset.quad9.tunnelDoHURL` to `https://9.9.9.9/dns-query`.
Its `serverURL` (`https://dns.quad9.net/dns-query`, a hostname, used for the
system DNS profile) stays as it is.

## Files to Modify

| File | Change |
|---|---|
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/UpstreamPreset.swift` | Item 1 |
| `ios/IBlockerKit/Sources/IBlockerKit/Shared/SharedSettings.swift` | Item 2 |
| `ios/IBlockerKit/Sources/IBlockerKit/Profile/DNSProviderPreset.swift` | Item 3 |
| `ios/IBlockerKit/Tests/IBlockerKitTests/` | Tests |

## Logging

Follow [docs/LOGGING.md](../../docs/LOGGING.md).

| Event | Level | Category | Details |
|---|---|---|---|
| Old Quad9 port-5053 URL replaced on read | `notice` | settings | old URL → new URL. Log once per process, not on every read. |

## Acceptance Criteria

Automated (`swift test --package-path ios/IBlockerKit`):

1. `UpstreamPreset` returns exactly the 7 presets in the table, in that
   order. All names are unique, and the labels of all UDP presets contain
   "unencrypted".
2. No source file under `ios/` contains `9.9.9.9:5053`, except the migration
   constant and its tests.
3. Stored `ResolverSettings` with alternative DoH
   `https://9.9.9.9:5053/dns-query` read back as the Quad9 preset config
   (`https://9.9.9.9/dns-query`, name "Quad9"), with the other fields
   unchanged. Settings derived from an old `upstreamConfig` with that URL
   give the same result.
4. A custom DoH URL other than the old Quad9 one is not changed.
5. Migrating `UpstreamConfig` DoH `https://1.1.1.2/dns-query` gives the
   name "Cloudflare (malware blocking)".
6. `DNSProviderPreset.quad9.tunnelDoHURL == "https://9.9.9.9/dns-query"`.
7. All existing tests pass, and IBlockerKit still builds on Linux.

Build:

8. `cd ios && xcodegen generate && xcodebuild build -project IBlocker.xcodeproj -scheme IBlocker -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`
   succeeds.

On device (manual):

9. Settings ▸ Use alternative DNS shows the two new Cloudflare choices.
   Selecting each one works; check with https://1.1.1.1/help and a log
   stream.
10. Quad9 works on the user's home network. In a log stream, lookups go to
    the alternative with no timeouts.

## Scope

**In scope:** items 1–3.

**Out of scope:**
- Other new providers. Google (8.8.8.8), OpenDNS and unfiltered AdGuard
  also work over IP-literal DoH, and can be added later if wanted.
- Hostname-based DoH (Mullvad, NextDNS, Control D, DNS4EU, CleanBrowsing).
  Their certificates don't cover their IPs.

## Pending Decisions

None.
