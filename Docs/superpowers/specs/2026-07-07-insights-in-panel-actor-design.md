# In-Panel Actor Detail — Design

**Date:** 2026-07-07
**Status:** Approved design, pre-implementation
**Revises:** Task 6 of `2026-07-07-insights-cast-panel-p1.md`. The person-page deep-link
(`presentPersonPage`, commit `9f4cdfe`; the paused-resume machinery, `80230e6`) is **replaced** by
an in-panel actor view. Video keeps playing throughout.

---

## What changes

Selecting a cast member no longer presents `PersonDetailViewController` over paused playback.
Instead the rail panel **crossfades in place** from the cast list to an actor view — portrait +
name + bio at the top, the actor's movies and shows in scrollable rows underneath — while video
continues playing. Menu reverse-crossfades back to the cast list; a second Menu closes the panel.

## Decisions

| Question | Decision |
|---|---|
| Navigation model | Two-state view *inside* the existing rail panel. No VC presentation, no pause. |
| Filmography interactivity | Display-only. Rows are focusable for browsing; **Select does nothing** in v1. Keeps the panel a calm read-only sidebar over live video. |
| Back navigation | **Menu** reverse-crossfades actor → cast list (panel stays open). A second Menu from the cast list closes the panel (unchanged). |
| Panel sizing | Panel **grows to a taller fixed height** for the actor state as it crossfades; content scrolls within. Cast-list state keeps its current height. |
| Loading | Crossfade **immediately** using the name + headshot already in hand; bio and filmography rows show a brief skeleton, then populate. |
| Data source | Reuse the existing `PersonFilmographyProviding` → `PersonDetail` (name, biography, portraitURL, movies, shows). No new fetch layer. |

## Architecture

The cast panel becomes a small two-state container. `InsightsCastListView` (built in P1 Task 5)
stays as-is and becomes the "list" state. A new `InsightsActorView` is the "detail" state. A thin
`InsightsPanelContainerView` owns both and the crossfade.

```
PlayerRailPanelView (glass chrome, unchanged — wraps any UIView)
        │
InsightsPanelContainerView (NEW — owns the two states + crossfade + height)
        ├── InsightsCastListView   (state .list — existing P1 view, unchanged)
        └── InsightsActorView      (state .actor — NEW: portrait, name, bio, films/shows rows)
```

- **`InsightsCastListView.onSelect`** (already `(MediaPerson) -> Void`) is rewired by the
  container to trigger the crossfade instead of calling back out to the view controller.
- The container is what `PlayerContainerViewController` presents via `presentRailPanel`; it
  exposes the same `init(cast:)` shape plus a data-loading closure (see Data flow).

### Crossfade + height

Both child views are stacked in the container. Crossfade = `UIView.transition` /
alpha animation (0.2s, matching the panel's `presentDuration`), the outgoing view faded to 0
and removed from the focus path, the incoming view faded to 1. The container animates its own
height constraint from the list height to the actor cap in the same animation block, so
`PlayerRailPanelView`'s `bottomAnchor == rail.topAnchor - gap` keeps it anchored above the rail
as it grows upward. Actor cap respects the panel's existing `maxHeight (560)`; overflow scrolls.

### Focus

- Entering the actor state: focus pins to the first focusable element (portrait region or first
  film poster), then frees (the pin-then-no-bounce pattern already used by `InsightsCastListView`
  and `UpNextListView`).
- Menu handling: the container intercepts `.menu` in `pressesBegan` when in the actor state →
  reverse-crossfade to `.list`, restore focus to the previously selected cast row, and **consume**
  the press so `PlayerRailPanelView` does not dismiss the whole panel. In the `.list` state the
  container does NOT consume `.menu`, so it bubbles to `PlayerRailPanelView` and closes the panel
  (unchanged P1 behavior). This mirrors the panel's own Menu ownership rather than fighting it.

## Data flow

`InsightsActorView` needs `PersonDetail`. The container is handed a loader closure by
`PlayerContainerViewController`:

```
onSelect(person):
  container.crossfadeToActor(seed: person)      // shows name + headshot immediately, skeleton below
  Task:
    detail = try? await provider.load(person:)   // existing PersonFilmographyProvider
    if still on this actor (guard by a per-selection token) and detail != nil:
        actorView.populate(detail)               // bio + movies + shows fill in
    else:
        actorView.showBioUnavailable()           // graceful: portrait+name stay, films empty
```

- `PersonFilmographyProviding` and `PersonDetail` already exist and are `Sendable`; the provider
  is constructed the same way `PersonDetailViewController` constructs its default
  (`PersonFilmographyProvider()`).
- A per-selection token (monotonic Int, or the `MediaPerson.id`) guards against a slow load
  landing after the user has gone back to the list or picked a different actor.
- Portrait: `MediaPerson.imageURL` (already a TMDB `w342` headshot from P1) seeds it instantly;
  `PersonDetail.portraitURL` replaces it if present. Loaded via `ImageCacheManager.shared.image`.

## Filmography rows

Two horizontal rows ("Movies", "Shows"), each built from `PersonDetail.movies` / `.shows`
(`[FilmographyEntry]`). Reuse **`ShelfRowCell`** (`Rivulet/Views/Media/UIKit/Cells/ShelfRowCell.swift`)
— the same self-driven horizontal-collection row the Person detail page uses for these exact
shelves, so the posters render identically. Posters are focusable (so the row scrolls under focus)
but the plan wires **no `onSelect`** in v1 (a no-op). A row with no entries is hidden (not an
empty header). Note `ShelfRowCell` was built to be hosted in a diffable collection; the actor
view either hosts its own small diffable collection (as the Person page does) or embeds two
`ShelfRowCell`s directly in a vertical stack — the plan picks whichever is lighter for a panel
that only ever shows two fixed rows.

## What P1 code is removed / changed

Verified against the current tree (grep, 2026-07-07):

- `PlayerContainerViewController.presentPersonPage(_:)` — **removed**. Its `pause()`/`wasPlaying`/
  `resume()` logic and the `page.onDismiss = …` wiring (the only assignment to
  `PersonDetailViewController.onDismiss`, at container line ~998) go with it.
- `PersonDetailViewController.onDismiss` — the property added in P1 Task 6 is **removed**.
  Confirmed: its only assignment is the line above; nothing else reads it. (This is a DIFFERENT
  property from `PlayerContainerViewController.onDismiss` at container line 60, which is the
  player-closed callback and **stays**.)
- The `dismiss(animated:completion:)` guard added in P1 Task 6 (`presentedViewController != nil`)
  — **removed**. Confirmed: `presentPersonPage`'s `present(page, animated:)` was the only VC
  presentation in the container (the rail panel uses `PlayerRailPanelView.present`, which adds a
  `UIView`, not a presented VC). With it gone nothing presents a VC over the player, so the guard
  is dead. Removing it restores the container's dismiss ladder to its pre-P1-Task-6 shape.
- `rail.onInsights` closure — now presents `InsightsPanelContainerView` (with the loader) instead
  of `InsightsCastListView` directly; the `onSelect` no longer calls `presentPersonPage`.

`PersonDetailViewController` itself stays (still reached via deep links elsewhere in the app —
e.g. `PreviewCarouselViewController`).

## Error / edge handling

- Bio/filmography load fails or returns nil → portrait + name remain, a quiet "No details
  available" line replaces the skeleton, film rows stay hidden. No error dialog, no retry.
- Actor has a headshot but no portrait from `PersonDetail` → keep the seeded `w342` headshot.
- No headshot at all → the same fallback person glyph the cast row uses.
- Rapid selection / back-and-forth → the per-selection token drops stale loads.

## Testing

- **Unit:** the per-selection token guard (a stale load does not overwrite a newer actor / the
  list state) is the one piece of non-trivial logic worth a unit test; factor it so it can be
  tested without UIKit (e.g. a small `InsightsActorLoadCoordinator` that owns the token and
  decides apply-vs-drop). Mapper/loader from P1 are untouched.
- **Simulator (folds into the P1 Task 7 checklist):** Select a cast member → panel crossfades
  in place, video keeps playing (no pause); name + headshot instant, bio + films fill in; focus
  lands cleanly, long bio scrolls; Menu returns to the cast list with focus restored; second Menu
  closes the panel; film posters browse but do nothing on Select; actor with missing bio shows the
  graceful state.

## Out of scope (possible later)

- Making filmography posters actionable (play server titles / open metadata detail).
- Crew (directors/writers) in the actor view.
- Any of the P2 trivia work (separate spec).
