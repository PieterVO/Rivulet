# Menu-Button Back Navigation (staged) — Design

Date: 2026-07-10
Issues: #19 (Back button should scroll back up to top row), #192 (Back button on remote takes you all the way back to Home)

## Goal

Make the Menu ("back") button on the Siri Remote walk backward in **stages**, matching the
official Plex app, instead of jumping straight to the sidebar or exiting the app.

On a content grid (Home, Library, Discover, Search), the stages are:

1. **Scroll to top** — if focus is deep in the grid, the first Menu press resets the
   scroll position to the top and moves focus to the hero (first item, first row).
2. **Open sidebar** — once already at the top, the next Menu press opens the sidebar
   (the system's native `.sidebarAdaptable` reveal — focus moves left off content).
3. **Go Home** (Library/Discover/etc. only) — once the sidebar is open, the next Menu
   press selects the Home tab.

On the **Home** tab the sequence is only stages 1 → 2: scroll to top, then open the
sidebar. It never navigates away (there is nowhere "more back" to go) and never exits
the app. A further Menu press from the open sidebar on Home stays put — the current
behavior.

This delivers both issues: #19 is stage 1; #192 is stage 3.

## Behavior model — driven by focus location, not a press counter

The stage is decided by **where focus currently is** when Menu is pressed, not by
counting presses. A press counter desyncs the moment the user moves focus between
presses; a focus-location check is self-correcting.

| Focus location when Menu pressed        | Action                                   |
|-----------------------------------------|------------------------------------------|
| Content grid, NOT the hero section      | Consume → scroll to top, focus the hero  |
| Content grid, hero section (at top)     | Do not consume → system opens the sidebar|
| Inside the sidebar, `selectedTab != .home` | Consume → set `selectedTab = .home`   |
| Inside the sidebar, `selectedTab == .home` | Do not consume → stays (current swallow)|

The same model applies uniformly to Home, Library, Discover, and Search grids. Only the
sidebar→Home step matters in practice for Library (issue #192), but the logic is uniform
across modes.

## Architecture — two independent pieces

The three stages split cleanly across two existing seams, because after stage 2 focus
has physically left `PlexHomeViewController` and entered the system-owned sidebar. So the
home VC can only own stages 1 and 2; stage 3 is a sidebar/shell concern.

### Piece A — Menu interception in `PlexHomeViewController` (stages 1 → 2)

File: `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift`

Add a `pressesBegan(_:with:)` override. For a `.menu` press:

- Resolve whether the currently focused view belongs to the **hero section**. The VC
  already has `heroSectionIndex` (`:1246`) and the focus router already reasons about
  the focused section (`focusedSectionIndex(in:)` `:4643`, used from
  `didUpdateFocusIn` `:4543`). Track the current focused section (or read
  `UIScreen.main.focusedView` / the last-focused index path) to decide.
- **Not on the hero:** consume the press. Scroll to the top and route focus to the hero:
  - Expose the existing top routine — `scrollHeroIntoView()` (`:4053`) is currently
    `private`; either drop `private` or add a small public
    `scrollToTopAndFocusHero()` that calls it.
  - Set `needsInitialHeroFocus = true` (`:1244`) and `setNeedsFocusUpdate()` /
    `updateFocusIfNeeded()` so `preferredFocusEnvironments` (`:4165`, which already
    routes to the hero cell while `needsInitialHeroFocus` is set, `:4187`) lands focus
    on the hero.
- **Already on the hero:** call `super.pressesBegan(presses, with: event)` so the press
  bubbles to the `.sidebarAdaptable` shell, which performs the native sidebar reveal.
  (Per the tvOS rule: only consume Menu when there is somewhere back to go; otherwise
  let it bubble.)

This is mode-agnostic — it works for `.home`, `.library`, `.discover`, `.search`
because every mode has a hero section and the same top routine.

### Piece B — Sidebar Menu → Home (stage 3)

File: `Rivulet/Views/TVNavigation/TVSidebarView.swift`

The root `.onExitCommand { }` at `:111` is currently an **empty swallow** (it stops Menu
from backgrounding the app at the shell level). Replace the empty body with:

- Find the sidebar collection view via the existing helper
  `findSidebarCollectionView(in:)` (`:880`).
- Check whether the **currently focused view is a descendant of the sidebar collection
  view** (`UIScreen.main.focusedView?.isDescendant(of: sidebarCV)`). This is the gate
  that says "focus is in the sidebar."
- If focus is in the sidebar **and** `selectedTab != .home`: set `selectedTab = .home`
  (consumes the press by handling it).
- Otherwise: do nothing (leave the swallow), so content-focus presses fall through to
  Piece A / the system's native sidebar reveal, and an already-Home sidebar press stays.

`selectedTab` is private `@State` inside `TVSidebarView` (`:35`), so this assignment
happens in-view — no new cross-boundary API. Setting `selectedTab = .home` flows through
the existing `.onChange(of: selectedTab)` (`:116`) which resets nesting and re-syncs
structure.

## Key risk to resolve during implementation

The two Menu handlers (Piece A `pressesBegan` in content, Piece B `.onExitCommand` in
the shell) must not both act on one press.

1. **Ordering:** presses go to the focused view first (tvOS rule), so Piece A runs
   before the press can bubble to Piece B. When Piece A consumes (stage 1) the press
   never reaches Piece B. When Piece A calls `super` (stage 2, focus at hero, focus
   still in content), Piece B's descendant check returns **false** (focus is not yet in
   the sidebar), so Piece B does nothing and the system opens the sidebar. Only on the
   **next** press — focus now in the sidebar — does Piece B's gate pass and switch to
   Home. This is what produces the true 3-press sequence.

2. **Does `.onExitCommand` even fire while focus is in the system-owned sidebar
   collection view?** This must be verified on-device. If the system consumes Menu in
   the sidebar before `.onExitCommand` sees it, Piece B moves to a swizzle on the
   sidebar collection view's `pressesBegan` — the same access path already used by
   `installSidebarFocusGuard()` / `overrideSidebarFocusBehavior(on:)` (`:815`–`:877`),
   which already swizzles `shouldUpdateFocus(in:)` on that class. This is a
   contingency, not the primary plan.

## Testing

This is pure focus/press behavior with no unit-testable surface. Verify manually
on-device (simulator focus/Menu behavior is not always faithful):

- **Library, deep in grid:** Menu → scrolls to top, focus on hero. Menu → sidebar opens.
  Menu → Home tab selected. (3 presses.)
- **Home, deep in grid:** Menu → scrolls to top, focus on hero. Menu → sidebar opens.
  Menu again → stays (no navigation, no exit). (2 meaningful presses.)
- **Discover / Search:** stage 1 (scroll to top) works; stage 3 returns to Home.
- Regression: normal per-item Menu dismissal inside the preview carousel / expanded
  detail (which own Menu at the detail layer) is unaffected — Piece A only overrides
  Menu at the `PlexHomeViewController` grid level, and the detail layer sits above it.

## Non-goals

- No new programmatic "open sidebar" API — stage 2 uses the OS's native reveal.
- No change to player, Settings, or modal Menu handling.
- No press-count state object — stage is inferred from live focus location.
