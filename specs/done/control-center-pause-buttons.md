---
name: Control Center pause buttons
id: spec-50f408d0
description: "Four Control Center buttons pausing ad blocking for 5/10/30/60 min, each with a custom numbered symbol and title"
dependencies: null
priority: medium
complexity: null
status: done
tags:
- controls
- widgets
scope:
  in: null
  out: null
feature_root_id: B-3a52edcd
---
# Control Center pause buttons

## Objective

Add four Control Center buttons that pause ad blocking for a fixed time: 5,
10, 30 and 60 minutes. Each button shows its number clearly, in every control
size, so you can tell them apart at a glance.

This is `docs/ROADMAP.md` item 6 (Quick controls). Agreed with the user on
2026-10-26: fixed durations, no configurable control.

## Behaviour

- **Four separate controls** (`ControlWidgetButton`, `StaticControlConfiguration`),
  added to `IBlockerWidgetBundle` next to the existing `ProtectionControl`
  toggle. The toggle doesn't change.
- **Each has its own kind,** defined in `WidgetKinds`, for example
  `net.renalias.adblocker.control.pause5`, and so on for 10, 30 and 60.
- **Gallery names:** "Pause 5 min", "Pause 10 min", "Pause 30 min" and
  "Pause 60 min". Description: "Pause ad blocking for N minutes."
- **Pressing a button:**
  - **Protection on:** pause for N minutes from now. This sets
    `SharedSettings.pausedUntil = now + N min`. If a pause is already
    running, the new deadline replaces it. A shorter duration is allowed.
    The tunnel already re-reads `pausedUntil` every 2 s, so no IPC is
    needed.
  - Then reload the widgets and the toggle control, the same way
    `VPNControl.reloadWidgets` does.
  - **Protection off** (`SharedSettings.protectionActive == false`): do
    nothing. Pausing protection that's already off makes no sense.
- **Pause ended:** the "Pause ended" notification from `spec-8d9a86ec` works
  unchanged, since the tunnel schedules it from `pausedUntil`.

## Visible numbers

> **Resolved on device, 2026-10-26:** custom SF Symbols rendered blank in
> Control Center. That happened even with a v3 template and with copies in
> both the widget and app catalogs. The user chose built-in numbered symbols
> instead: `5.circle`, `10.circle` and `30.circle`. The **60-minute button is
> deferred**, because no built-in numbered symbol goes above 50. Defect
> `B-11968724` does this. The rest of this section is the original plan, kept
> for reference.


- **Label title:** "Pause 5 min", "Pause 10 min", "Pause 30 min", "Pause 60
  min". This is shown in the medium and large control sizes.
- **Icon:** the number must be readable in the small (1×1) size, where only
  the icon shows. SF Symbols' numbered circles stop at 50, so use **custom
  SF Symbols** for all four, to keep them consistent:
  - names `pause.5`, `pause.10`, `pause.30`, `pause.60`
  - the number in bold digits, filling most of the symbol, inside a circle
    or rounded square
  - add them as symbol sets in a new asset catalog in the widget target,
    `ios/Widgets/Assets.xcassets`. Include it via `ios/project.yml` (XcodeGen
    is the source of truth; never edit the generated `.xcodeproj`).
  - a symbol template with only the Regular-M glyph is enough
  - reference them with `Image("pause.N")` / `Label(_:image:)` in the
    control's label, so Control Center renders them as a template, tinted
    like system symbols.
- **Tint:** orange, so the pause buttons look different from the green on/off
  toggle.

## Acceptance Criteria

1. The widget extension contains four Control Center button controls with
   the kinds, gallery names, descriptions and titles listed above.
2. Pressing a button while protection is on sets `pausedUntil` to now plus N
   minutes, replacing any existing pause, and reloads widgets and the toggle.
   Pressing it while protection is off changes nothing.
3. The pause-deadline calculation (duration in, deadline out, replacing an
   existing pause, no-op when off) is a small function in IBlockerKit, with
   unit tests. The intents call it.
4. The four custom symbols exist in `ios/Widgets/Assets.xcassets`, the asset
   catalog is part of the widget target via `ios/project.yml`, and each
   control's label uses its symbol.
5. `swift test --package-path ios/IBlockerKit` passes, and the iOS app builds
   after `xcodegen generate` (CI).
6. The events in the Logging section are logged at the stated levels.
7. **Manual (on device, by the user):**
   - All four buttons can be added to Control Center.
   - Each shows its number clearly at the small size and its title at the
     medium size.
   - Pressing one pauses blocking, and the toggle and widgets show the
     paused state.
   - When the pause runs out, blocking resumes.

## Logging

Per [docs/LOGGING.md](../../docs/LOGGING.md): subsystem
`net.renalias.adblocker`, new category `controls`. Add it to the categories
list in `docs/LOGGING.md`.

| Event | Level | Example |
|---|---|---|
| Pause button pressed, pause set | notice | `pause button 30 min: paused until 14:05` |
| Pause button replaced a running pause | info | `pause button 10 min: replaced pause ending 14:20` |
| Pause button pressed while protection off | info | `pause button 5 min ignored: protection off` |
| Settings unavailable in the extension | error | `pause button 60 min: shared settings unavailable` |

## Scope

**In:**
- the four button controls
- custom symbols
- the pause-deadline helper and its tests
- `WidgetKinds` additions
- `project.yml` asset catalog
- the logging category
- a `docs/ROADMAP.md` status update

**Out:**
- configurable durations
- showing remaining time or a "Resume" state on the buttons
- changes to the on/off toggle, the Home or Lock Screen widgets, or the
  Shortcuts pause intent (it keeps its own durations)

## Files to Add/Modify (hints)

- **New:** `ios/Widgets/PauseControls.swift`: the four controls and their
  intent or intents. The widget target doesn't link IBlockerUI, so don't use
  `VPNControl`. Write `SharedSettings` through `WidgetEnvironment.settings`,
  like `ProtectionControl.swift`.
- **New:** `ios/Widgets/Assets.xcassets/` with `pause.5.symbolset`,
  `pause.10.symbolset`, `pause.30.symbolset` and `pause.60.symbolset`.
- `ios/Widgets/IBlockerWidgetBundle.swift`: register the controls.
- `ios/IBlockerKit/Sources/IBlockerKit/Shared/WidgetKinds.swift`: the new
  kinds.
- **New:** a pause-deadline helper in `ios/IBlockerKit/Sources/IBlockerKit/Shared/`,
  plus tests.
- `ios/project.yml`: only if the asset catalog isn't picked up by the
  existing `Widgets` source path. Check after `xcodegen generate`.
- `docs/LOGGING.md`, `docs/ROADMAP.md`.
