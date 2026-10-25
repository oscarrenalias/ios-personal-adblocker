# Roadmap

Planned features, with what already exists, what's missing, and what each one
depends on. Bugs and weaknesses are in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).
Each feature becomes one or more specs in `specs/` when we start it. Record
the spec IDs here.

Written 2026-10-25.

## Suggested order

| # | Feature | Depends on | Size |
|---|---|---|---|
| 0 | Finish reboot robustness (defects `B-0d1e113d`, `B-28826355`) | — | in progress |
| 1 | [Configurable failure policy](#configurable-failure-policy) (folded into the alternative resolver spec) | KI-1 part 1 (done) | M |
| 2 | [Reliable blocklist updates](#reliable-blocklist-updates) | — (can run alongside 1) | M |
| 3 | [DNS caching](#dns-caching) | 1 (sits in front of the router) | M |
| 4 | [Explain each decision](#explain-each-decision) + [Rule testing](#rule-testing) | 3 (to report "from cache") | L |
| 5 | [Protection health indicator](#protection-health-indicator) | 0, 1 (status signals) | M |
| 6 | [Quick controls and profiles](#quick-controls-and-profiles) | profiles defined (open question) | M |

Why this order:
- **1 first:** it decides how failures behave, and it's a small addition to a
  spec that's already written.
- **2 is independent** and protects against the worst silent failure: a bad
  download wiping out a list.
- **Cache before explanations,** so explanations can include "answered from
  cache".
- **Health last,** because it summarises signals the earlier work produces:
  rules loaded, resolver status, fallback in use.

---

## Configurable failure policy

**Want:** the user chooses whether connectivity or filtering wins when
something fails, and sees clearly when a fallback changes encryption or which
resolver sees their lookups.

**Exists / planned:** spec `spec-c7e3c45d` (alternative resolver with
failover) always falls back from the encrypted alternative to network DNS.
That's connectivity first, and the status line says "Network DNS — X
unreachable, retrying".

**Missing:**
- An **encryption policy** setting:
  - "Fall back to network DNS" (connectivity)
  - "Never fall back" (privacy). Lookups fail while the encrypted resolver is
    down.
- A **filtering policy** for when rules aren't loaded, for example at boot
  before the first unlock or after a failed load:
  - "Allow with built-in rules" (today's behaviour)
  - "Block everything until rules load"
- A visible warning, on the Dashboard and in Settings, whenever lookups go
  unencrypted, or to a different resolver than the one chosen, because of a
  fallback.

**Plan:** fold the encryption policy and its warnings into `spec-c7e3c45d`
before planning it. Add the filtering policy to the health work (5), which
already owns the "rules not loaded" state.

## Reliable blocklist updates

**Want:** download and validate before replacing the active list, keep the
last good version, reject malformed or unexpectedly empty updates, and show
list age and failures.

**Exists:** conditional GET with ETag and Last-Modified
(`FilterListUpdater`), a "not empty" check, and per-list rule count, last
fetched time and last error shown in Lists.

**Missing:**
- Validate a download before it replaces the cached copy:
  - It parses as a filter list (not an HTML error page).
  - It has a minimum number of valid rules, and enough lines parse.
  - It isn't suspiciously smaller than the last good version (for example,
    reject a drop of more than 50% unless forced).
- Keep the last good copy, and swap atomically only after validation passes.
- Show "using version from <date>, update rejected: <reason>".
- Show a stale warning when a list is older than N days.
- Related: KI-5 (background refresh probably never runs).

## DNS caching

**Want:** respect TTLs, cache negative answers appropriately, invalidate
entries when rules change, and offer a "clear cache" action.

**Exists:** nothing (KI-9). iOS caches on its own side too.

**Missing:**
- A bounded in-memory cache in the tunnel, keyed by name, type and class,
  sitting in front of the router.
- TTLs taken from the answer (lowest TTL in the answer section; SOA minimum
  for negative answers, with a cap).
- Entries cleared when rules reload, the allow/deny lists change, the resolver
  changes or the network changes.
- A "Clear DNS cache" button, with the cache's hit rate in diagnostics.
- Fold in KI-7: a short TTL for blocked answers, so pausing or allowing a site
  takes effect quickly.
- Memory limit: the extension has roughly 50 MB, so the cache needs a hard
  entry and byte limit.

## Explain each decision

**Want:** show which rule and list blocked a domain, which resolver answered
an allowed lookup, and whether the answer came from the cache.

**Exists:** a verdict only. `DomainMatcher` returns block, allow or none. The
compiled blocklist is one merged set of hashes, and
`QueryLogRecord.listId` is reserved but always 0.

**Missing:**
- **Attribution in the compiled format:** a new blob version that stores a
  source index next to each hash, plus a source table. Exception (`@@`)
  rules become a separate set, which also fixes KI-6.
- **Matcher explanation:** which suffix matched (for example,
  `ads.example.com` blocked by the rule `example.com`), and from which
  source: list name, user deny or allow, list exception, or built-in rules.
- **Log records:** the matching source, the resolver used (network,
  alternative or network-only name), and whether the answer came from the
  cache. They're all in the 64-byte record's reserved bytes.
- **UI:** tap a log entry to see the explanation.

**Note:** the matched rule's text can be rebuilt from the query itself, since
it's one of the query's own suffixes. So no domain strings need storing in the
blob.

## Rule testing

**Want:** enter a domain to see what would happen and why, without a live DNS
lookup, and preview how list changes would affect it.

**Exists:** "Verify blocking" (`BlockingTestView`) makes **live** lookups for
7 fixed domains.

**Missing:**
- **A "Test a domain" screen:** run the same matcher explanation as above in
  the app, against the compiled files and the user lists. No network involved.
- **Preview:** compile the changed list selection in memory and show the
  difference for the entered domain, plus the total rule count before and
  after.
- Built on the same explanation work as above, so plan them together.

## Protection health indicator

**Want:** tell "VPN connected" apart from "DNS is resolving and filtering
correctly", including a check through the system resolver.

**Exists:** the Dashboard shows the VPN connection state. `BlockingProbe` can
already resolve through the system resolver, but only on demand in "Verify
blocking".

**Missing:**
- A health model combining:
  - VPN state
  - whether the tunnel is reachable (IPC)
  - whether rules are fully loaded (from the reboot defect)
  - which resolver is in use, and whether it's a fallback
  - a periodic probe through the system resolver: one known-blocked and one
    known-allowed domain. Run it when the app is open, not in the background,
    to save battery.
- A single status: Healthy / Degraded (with the reason) / Not protected.
- The filtering policy from "Configurable failure policy" above.

## Quick controls and profiles

**Want:** widgets, Shortcuts and a Control Center toggle for timed pauses and
for switching protection profiles.

**Exists:**
- Home and Lock Screen widgets.
- A Control Center toggle (`ProtectionControl`).
- Shortcuts: enable, disable, pause (5, 15 or 60 min), resume, update lists.

**Missing:**
- **Profiles,** which aren't defined yet. Open question: what does a profile
  contain? For example, lists and resolver choice ("Strict", "Relaxed"),
  per-network automatic switching, or something else.
- Shortcuts and widget actions to switch profile.
- Pause lengths in Control Center. Today the toggle is only on/off.
