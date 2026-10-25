---
name: Reliable blocklist updates
id: spec-27c7b48b
description: "Validate list downloads before replacing (keep last good), single serialized FilterListStore for all update paths (KI-14), working background refresh (KI-5), stale/rejected display in Lists"
dependencies: null
priority: high
complexity: null
status: planned
tags:
- lists
- reliability
scope:
  in: null
  out: null
feature_root_id: B-538bb61d
---
# Reliable blocklist updates

## Objective

A list update can never silently make blocking worse. Downloads are validated
before they replace the active copy, the last good copy is kept, background
refresh actually runs, and all update paths go through one serialized
pipeline. The Lists screen shows each list's age, staleness and any rejected
update.

This covers `docs/ROADMAP.md` item 2, plus `docs/KNOWN-ISSUES.md` KI-5 and
KI-14.

**Depends on:** `spec-54a5b4a5` (UI polish) being merged. It changes the
"updated … ago" text in `FilterListsView` that this spec builds on. Don't
plan before then.

## Problems to Fix

1. **No validation.** `FilterListUpdater.update`
   (`ios/IBlockerKit/Sources/IBlockerKit/Lists/FilterListUpdater.swift`)
   writes any non-empty 200 response straight over the cached list. An HTML
   error page, a truncated download or a publisher mistake replaces a good
   list, and the next compile drops that list's rules without any warning.
2. **KI-5:** `ListRefreshScheduler`
   (`ios/IBlockerKit/Sources/IBlockerUI/System/ListRefreshScheduler.swift`)
   submits a `BGAppRefreshTaskRequest`, but `ios/App/Info.plist` has no
   `UIBackgroundModes` → `fetch`. The submit error is swallowed by `try?`, so
   lists only refresh when the app is opened and they're over 24 h old
   (`FilterListsViewModel.refreshIfStale`).
3. **KI-14:** three paths independently load, update, compile and save
   `sources.json`, with nothing coordinating them:
   - `FilterListsViewModel` (`updateAndCompile`, `compileOnly`, source
     changes)
   - `ListRefreshScheduler.handle`
   - `UpdateListsIntent.perform`
     (`ios/IBlockerKit/Sources/IBlockerUI/System/IBlockerIntents.swift`)

   Concurrent runs can lose changes or interleave compiles.
4. The Lists screen shows age and last error, but not that an update was
   rejected while an older good version is still in use, and it doesn't warn
   about stale lists.

## Changes

### 1. Validation (pure logic, IBlockerKit)

A `FilterListValidator` that takes the downloaded text and the previous
accepted entry count (`Int?`) and returns `accept(entryCount)` or
`reject(reason)`. The rules, in order:

| Rule | Reject when | Reason text |
|---|---|---|
| Not a list | the first 1 KB, trimmed and lowercased, starts with `<!doctype` or `<html`, or contains `<html` | "Server returned a web page, not a list" |
| Empty | `FilterListParser.parse` finds 0 block domains | "Download contained no rules" |
| Mostly unparseable | `skippedLines > 0.5 × (totalLines − commentLines)` | "Most lines couldn't be read (N of M)" |
| Shrank suspiciously | there's a previous count, and new count < 50 % of it | "Has N rules, was M — kept the previous version" |

Bundled sources (`SeedRules`) aren't downloaded, so they aren't validated.

### 2. Atomic replace and last-good copy

- The updater writes the download to a temporary file in the lists cache
  directory, validates it, and only then moves it over
  `cachedListURL(sourceID:)` (an atomic replace).
- A rejected download is deleted, and the existing cached file (the last
  good version) stays in use.
- A 304 response counts as a successful check with no change, as today.
- `FilterListMetadata` gains:
  - `lastChecked: Date?`: the last attempt, whatever the outcome
  - `lastAccepted: Date?`: the last time a download replaced the cache.
    Migrate from `lastFetched`: if `lastAccepted` is nil and `lastFetched` is
    set, use `lastFetched`.
  - `lastRejection: String?`: set on rejection, and cleared on the next
    accepted download or 304
  - `entryCount`: still only updated by the compiler. The validator compares
    against the previous `entryCount`.

  `lastError` keeps its current meaning: network or HTTP failures.

### 3. One serialized update pipeline (KI-14)

- A `FilterListStore` actor in `IBlockerKit` is the only code that loads,
  modifies and saves `FilterListState`. It provides:
  - `mutate { state in … }`: load, apply, save
  - `updateAll(force:) -> UpdateSummary`: fetch, validate, compile, save
  - `compile()`

  Calls run one at a time. If a second `updateAll` arrives while one is
  running, it waits and then returns the same summary instead of
  downloading again.
- `FilterListsViewModel`, `ListRefreshScheduler.handle` and
  `UpdateListsIntent.perform` all go through one shared store instance
  (`AppEnvironment.listStore`). None of them calls
  `FilterListUpdater`/`BlocklistCompiler`/`FilterListState.save` directly
  any more.
- The tunnel extension only reads the compiled files and doesn't use the
  store. That's unchanged.

### 4. Background refresh (KI-5)

- Add `UIBackgroundModes` = `[fetch]` to `ios/App/Info.plist`. The
  `BGTaskSchedulerPermittedIdentifiers` entry already exists.
- `ListRefreshScheduler.schedule()` logs submit errors instead of using
  `try?`. The handler uses the store's `updateAll(force: false)`.
- Keep `refreshIfStale` (24 h) as the foreground safety net.

### 5. Lists UI

In `FilterListsView`
(`ios/IBlockerKit/Sources/IBlockerUI/Lists/FilterListsView.swift`), under each
enabled downloadable list:

- the existing rule count and age line. The age uses `lastAccepted`, through
  the `ListAgeText` added by the UI polish spec.
- if `lastRejection` is set: an orange line **"Update rejected: <reason>.
  Using the version from <age>."**
- if `lastAccepted` is more than **7 days** ago: an orange **"Stale"** badge
  next to the age.
- network errors (`lastError`) are shown as today.

The "is it stale?" decision is a pure function (`ListFreshness`), so it can
be tested.

### 6. Docs

- `docs/KNOWN-ISSUES.md`: mark KI-5 and KI-14 as fixed, and link this spec.
- `docs/ROADMAP.md`: mark item 2 as done.
- `docs/ARCHITECTURE.md`: describe the update pipeline (store, validation,
  atomic replace).

## Files to Modify

| File | Change |
|---|---|
| `ios/IBlockerKit/Sources/IBlockerKit/Lists/FilterListValidator.swift` (new) | Item 1 |
| `ios/IBlockerKit/Sources/IBlockerKit/Lists/FilterListUpdater.swift` | Item 2 |
| `ios/IBlockerKit/Sources/IBlockerKit/Lists/FilterListSource.swift` | Metadata fields (item 2) |
| `ios/IBlockerKit/Sources/IBlockerKit/Lists/FilterListStore.swift` (new) | Item 3 |
| `ios/IBlockerKit/Sources/IBlockerUI/Lists/FilterListsViewModel.swift` | Use the store (item 3) |
| `ios/IBlockerKit/Sources/IBlockerUI/System/ListRefreshScheduler.swift`, `IBlockerIntents.swift`, `AppEnvironment.swift` | Use the store; log scheduling (items 3, 4) |
| `ios/App/Info.plist` | `UIBackgroundModes` (item 4) |
| `ios/IBlockerKit/Sources/IBlockerUI/Lists/FilterListsView.swift`, `ios/IBlockerKit/Sources/IBlockerKit/Lists/ListFreshness.swift` (new) | Item 5 |
| `ios/IBlockerKit/Tests/IBlockerKitTests/` | Tests |
| `docs/KNOWN-ISSUES.md`, `docs/ROADMAP.md`, `docs/ARCHITECTURE.md` | Item 6 |

## Logging

Follow [docs/LOGGING.md](../../docs/LOGGING.md). Category `lists` (new) for
the store, updater and validator, and `app` for scheduling.

| Event | Level | Details |
|---|---|---|
| Update run started / finished | `info` | trigger (user / background / shortcut / stale-check), duration, counts updated / unchanged / rejected / failed |
| List download accepted | `info` | source id, new count, previous count, bytes |
| List download rejected | `notice` | source id, reason, new vs previous count |
| Network or HTTP failure | `notice` | source id, error |
| Concurrent update joined an in-flight run | `debug` | trigger |
| BG refresh scheduled / submit failed | `info` / `error` | earliest begin date / error |
| BG refresh task ran / expired | `notice` | outcome |

## Acceptance Criteria

Automated (`swift test --package-path ios/IBlockerKit`):

1. Validator: an HTML page (`<!DOCTYPE html>`), an empty list, a list where
   60 % of non-comment lines are unparseable, and a list with 40 % of the
   previous count are each rejected with the reason text in the table. A
   valid list with 60 % of the previous count, or with no previous count, is
   accepted.
2. Updater with an injected fetch:
   - a rejected 200 response leaves the cached file byte-identical, sets
     `lastRejection` and `lastChecked`, and doesn't change `lastAccepted`
   - an accepted one replaces the file and clears `lastRejection`
   - no temporary files are left behind in either case
3. Metadata migration: decoding old JSON with only `lastFetched` gives
   `lastAccepted == lastFetched`.
4. Store: two concurrent `updateAll` calls cause exactly one fetch per
   source (counted by the injected fetch), and both get the same summary.
   Concurrent `mutate` calls don't lose updates (100 parallel increments of
   a test field all land).
5. `ListFreshness` marks a list stale at more than 7 days and fresh at 7
   days or less.
6. All existing tests pass, and IBlockerKit builds on Linux.

Code review:

7. `FilterListsViewModel`, `ListRefreshScheduler` and `UpdateListsIntent`
   no longer call `FilterListUpdater`, `BlocklistCompiler.compile` or
   `FilterListState.save` directly.
8. `ios/App/Info.plist` contains `UIBackgroundModes` with `fetch`, and the
   scheduler has no `try?` around `submit`.
9. Every Logging-table event is present at its level.

Build:

10. `cd ios && xcodegen generate && xcodebuild build -project IBlocker.xcodeproj -scheme IBlocker -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`
    succeeds.

On device (manual):

11. Lists shows the age per list, and "Stale" doesn't appear for freshly
    updated lists.
12. Add a custom list whose URL returns a web page (for example
    `https://example.com/`): it's rejected with "Server returned a web page,
    not a list". Existing lists are unaffected.
13. Background refresh: in a log stream, `BG refresh scheduled` appears after
    launch. Optionally, trigger the task from Xcode's debugger
    (`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"<bundle id>.refresh"]`)
    and see "BG refresh task ran".

## Scope

**In scope:** items 1–6.

**Out of scope:**
- Accepting a rejected update manually (an "accept anyway" button). A
  possible follow-up.
- List signatures or checksums. Publishers don't provide them.
- Changing which lists are offered.

## Pending Decisions

- **Thresholds** (50 % shrink, 50 % unparseable, 7 days stale) are starting
  values.
