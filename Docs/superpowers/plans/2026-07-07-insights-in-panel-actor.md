# In-Panel Actor Detail Implementation Plan

> **For agentic workers:** implement this as ONE cohesive change (it is a single panel becoming two-state; splitting it fights the shared files). Follow TDD for the one unit-testable piece (the load coordinator). Load the `rivulet-tvos-uikit` skill before writing UIKit.

**Goal:** Replace the cast panel's person-page deep link with an in-place crossfade to an actor view (portrait + name + bio + movies/shows rows) while video keeps playing.

**Architecture:** The rail panel's content becomes `InsightsPanelContainerView`, a two-state view owning the existing `InsightsCastListView` (state `.list`) and a new `InsightsActorView` (state `.actor`). Selecting a cast member crossfades list→actor and kicks a `PersonFilmographyProvider.load`; Menu in the actor state reverse-crossfades back. `InsightsActorView` reuses `PersonHeaderCell` + `ShelfRowCell` in a small collection view exactly as `PersonDetailViewController` does, minus VC presentation.

**Tech Stack:** Swift 6 / tvOS 26 UIKit, Combine, XCTest.

Spec: `Docs/superpowers/specs/2026-07-07-insights-in-panel-actor-design.md`.

## Global Constraints

- Swift 6, tvOS 26+. UIKit player chrome; match existing style. Video MUST keep playing — no `pause()`/`resume()` anywhere in this flow.
- Glass focus style: focused bg white 0.18 / border 0.25; unfocused 0.08/0.08; scale 1.02.
- tvOS Select on plain UIControl → handle `.select` in `pressesBegan`.
- Menu ownership: in `.actor` state the container CONSUMES `.menu` (→ back to `.list`); in `.list` state it does NOT (bubbles to `PlayerRailPanelView`, which closes the panel). Never swallow `.menu` in `.list`.
- Filmography posters: focusable, but NO `onSelect` wired (no-op in v1).
- Build: `xcodebuild -scheme Rivulet -destination "platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3" -derivedDataPath /tmp/rivulet-insights-dd build 2>&1 | tail -5`. NEVER omit `-derivedDataPath /tmp/rivulet-insights-dd`.
- Tests: same with `test -only-testing:RivuletTests/InsightsActorLoadCoordinatorTests`.
- Branch: `feature/insights-cast-panel`. Commit locally; do not push.

## Reference facts (verified in tree 2026-07-07)

- `InsightsCastListView(cast: [MediaPerson], onSelect: @escaping (MediaPerson) -> Void)` — `Rivulet/Views/Player/UIKit/PlayerInsightsPanelView.swift`. Keep as-is; the container supplies its `onSelect`.
- `PersonFilmographyProvider` — `Rivulet/Services/MediaProvider/Person/PersonFilmographyProvider.swift:135`, `nonisolated init(...)` with defaults, conforms to `PersonFilmographyProviding { func load(person: MediaPerson) async throws -> PersonDetail }` (`Rivulet/Models/Media/PersonDetail.swift:20`).
- `PersonDetail { id, name, biography: String?, portraitURL: URL?, movies: [FilmographyEntry], shows: [FilmographyEntry] }`; `FilmographyEntry { item: MediaItem, isOnServer: Bool }`.
- `PersonHeaderCell` — `Rivulet/Views/Media/Person/UIKit/PersonHeaderCell.swift`, `reuseID = "PersonHeaderCell"`, `configure(name:biography:portraitURL:isLoading:onMore:)`.
- `ShelfRowCell` — `Rivulet/Views/Media/UIKit/Cells/ShelfRowCell.swift`, `reuseID`, `headerTitle`, `cellProvider`, `onSelect`, `configure(kind:realCount:hasSkeleton:contentToken:initialOffset:)`, inner `PosterCell`. `PersonDetailViewController.configureShelf` (lines ~343-375) is the exact usage template — copy its shelf wiring but leave `onSelect` unset.
- `PlayerRailPanelView.present(content:width:in:aboveRail:towards:)` wraps any `UIView`; caps `maxHeight = 560`; anchors `bottomAnchor == rail.topAnchor - gap`, `trailingAnchor == rail.trailingAnchor`. It downcasts content for hooks — a new content type that needs a present-time hook must be added to those downcasts (check `PlayerRailPanelView.present`).
- Container wiring to change lives in `PlayerContainerViewController.swift`: `rail.onInsights` closure (~line 935), `presentPersonPage` (~line 989), the P1-Task-6 `dismiss` guard (`presentedViewController != nil`, ~line 359), and `PersonDetailViewController.onDismiss` set at ~line 998.

---

### Task A: Remove the P1 person-page deep link

**Files:** `Rivulet/Views/Player/PlayerContainerViewController.swift`, `Rivulet/Views/Media/Person/UIKit/PersonDetailViewController.swift`

- [ ] **Step 1:** In `PlayerContainerViewController.swift`, delete the `presentPersonPage(_:)` method entirely (the one that calls `vm.pause()` / `present(page,...)` / `page.onDismiss = ... vm?.resume()`). Leave the container's OWN `onDismiss` property (line ~60) untouched — it is unrelated.
- [ ] **Step 2:** Delete the P1-Task-6 guard at the top of `dismiss(animated:completion:)`:
  ```swift
  if presentedViewController != nil {
      super.dismiss(animated: flag, completion: completion)
      return
  }
  ```
  Verify by reading the method that nothing below it depended on that early return (the rest of the ladder is unchanged from pre-P1-Task-6). If ANY other code in the container calls `present(_:animated:)` on a VC, STOP and report — the guard must stay. (Grep confirmed only `presentPersonPage` did; re-confirm.)
- [ ] **Step 3:** In `PersonDetailViewController.swift`, remove `var onDismiss: (() -> Void)?` and the `if isBeingDismissed { onDismiss?() }` line in `viewWillDisappear`. Grep the repo for `.onDismiss` on any `PersonDetailViewController` instance first; the only assignment was the one deleted in Step 1. (The container's own `onDismiss` and `PlayerRailPanelView.onDismiss` are different types — do not touch them.)
- [ ] **Step 4:** Build (app will not fully wire Insights select until Task D — but it must COMPILE; `rail.onInsights`'s `onSelect` still references the old path, so temporarily point it at an empty closure `{ _ in }` with a `// TODO(Task D)` marker, OR do Task A+D in one build. Prefer leaving `onSelect: { _ in }` so the build stays green.) Expected: BUILD SUCCEEDED.
- [ ] **Step 5:** Commit: `refactor(insights): remove person-page deep link ahead of in-panel actor view`.

---

### Task B: Load coordinator (TDD, unit-testable core)

**Files:** create `Rivulet/Views/Player/UIKit/InsightsActorLoadCoordinator.swift`; test `RivuletTests/Unit/InsightsActorLoadCoordinatorTests.swift`

**Interface produced:** a small `@MainActor` class that owns a monotonic selection token and decides whether a completed load should be applied or dropped.

```swift
@MainActor
final class InsightsActorLoadCoordinator {
    private var currentToken = 0
    /// Begin a new selection; returns the token to tag this load with.
    func begin() -> Int { currentToken += 1; return currentToken }
    /// True if `token` is still the active selection (apply the result);
    /// false if a newer selection or a return-to-list superseded it (drop).
    func isCurrent(_ token: Int) -> Bool { token == currentToken }
    /// Called when returning to the list state so a late load is dropped.
    func cancel() { currentToken += 1 }
}
```

- [ ] **Step 1:** Write failing tests: `begin` returns increasing tokens; `isCurrent` true for the latest token, false for a superseded one; after `cancel()` the previously-current token is no longer current.
- [ ] **Step 2:** Run → fail (type missing).
- [ ] **Step 3:** Implement the coordinator above.
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5:** Commit: `feat(insights): actor-load coordinator (stale-load guard)`.

---

### Task C: InsightsActorView

**Files:** create `Rivulet/Views/Player/UIKit/InsightsActorView.swift`

**Interface produced:** `final class InsightsActorView: UIView` with
`init(person: MediaPerson)` (seeds name + headshot immediately, shows skeleton below) and
`func populate(_ detail: PersonDetail)` / `func showDetailsUnavailable()`.

- [ ] **Step 1:** Build a `UICollectionView` (compositional layout) with three sections mirroring `PersonDetailViewController`: header (`PersonHeaderCell`, portrait from `person.imageURL`, `isLoading` true until populate; pass a no-op `onMore` — no full-screen bio sheet in-panel, or a simple inline expand later), then `movies` and `shows` (`ShelfRowCell`, hidden when empty). Copy `makeShelfSectionLayout` + `configureShelf` from `PersonDetailViewController` but wire NO `onSelect` on the shelves. Portrait/name come from `person`; `populate` swaps in `detail.biography`, `detail.movies`, `detail.shows` and flips `isLoading` off.
- [ ] **Step 2:** `showDetailsUnavailable()` sets a quiet "No details available" in the header's bio slot and leaves the shelves hidden.
- [ ] **Step 3:** Focus: pin first focus to the header/first poster then free (mirror `InsightsCastListView`'s pin-then-free). Do NOT consume `.menu` here — the container owns it.
- [ ] **Step 4:** Build. Expected: BUILD SUCCEEDED. (No unit test; collection wiring is verified in Task E on the sim.)
- [ ] **Step 5:** Commit: `feat(insights): in-panel actor view (portrait + bio + filmography rows)`.

---

### Task D: InsightsPanelContainerView + rewire

**Files:** create `Rivulet/Views/Player/UIKit/InsightsPanelContainerView.swift`; modify `PlayerContainerViewController.swift`; possibly `PlayerRailPanelView.swift` (present-time hook)

**Interface produced:** `final class InsightsPanelContainerView: UIView` with
`init(cast: [MediaPerson], provider: PersonFilmographyProviding = PersonFilmographyProvider())`.

- [ ] **Step 1:** Container owns an `InsightsCastListView` (built with `onSelect` → `crossfadeToActor`), a lazily-built `InsightsActorView`, an `InsightsActorLoadCoordinator`, and a `state: .list | .actor`. Both children stacked; height constraint animatable (list height ↔ actor cap ≤ 560).
- [ ] **Step 2:** `crossfadeToActor(_ person:)`: `let token = coordinator.begin()`; build `InsightsActorView(person:)`; alpha-crossfade (0.2s) list→actor while animating the container's height to the actor cap; move focus to actor; then `Task { let d = try? await provider.load(person:); guard coordinator.isCurrent(token) else { return }; if let d { actor.populate(d) } else { actor.showDetailsUnavailable() } }`.
- [ ] **Step 3:** Menu handling in `pressesBegan`: if `state == .actor` and press contains `.menu` → `coordinator.cancel()`, reverse-crossfade actor→list (animate height back), restore focus to the list, and RETURN (consume). Otherwise `super.pressesBegan` (so `.menu` in `.list` bubbles to the glass panel and closes it). `preferredFocusEnvironments` returns the active child.
- [ ] **Step 4:** In `PlayerContainerViewController`, change the `rail.onInsights` closure to present `InsightsPanelContainerView(cast: self.insightsCastCache)` via `presentRailPanel(...)` at an appropriate width (keep 480). Remove the temporary `{ _ in }` from Task A. If `InsightsPanelContainerView` needs a present-time hook (e.g. initial focus after real layout), add a downcast in `PlayerRailPanelView.present` alongside the existing ones.
- [ ] **Step 5:** Build. Expected: BUILD SUCCEEDED.
- [ ] **Step 6:** Commit: `feat(insights): two-state cast panel with in-place actor crossfade`.

---

### Task E: Verification (folds into P1 Task 7 sim checklist)

- [ ] **Step 1:** Build + install to sim `33E70EDB`.
- [ ] **Step 2:** Manual checklist (hand to user with the P1 checklist): Select a cast member → panel crossfades in place, **video keeps playing (no pause)**; name + headshot instant, bio + films fill in; focus lands cleanly; long bio scrolls; film rows browse but Select does nothing; empty-bio actor shows the graceful state; **Menu returns to the cast list with focus restored**; a second Menu closes the panel; rapid actor-switch / back never shows a stale actor's data.
- [ ] **Step 3:** Report results; fix any failure (systematic-debugging) and re-verify.

## Self-review checklist (run after writing all tasks)
- No `pause()`/`resume()`/`present(_:animated:)` remain in the Insights flow.
- Menu consumed in `.actor`, bubbled in `.list`.
- Stale-load guard applied before every `populate`.
- Shelves reuse `ShelfRowCell` with no `onSelect`.
