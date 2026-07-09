# HANDOFF: Insights Cast Panel P1 (feature/insights-cast-panel)

**Date:** 2026-07-07. **For:** any agent resuming this work fresh.

## UPDATE (2026-07-07, later): Tasks 1–6 COMPLETE + final review done; only Task 7 (sim) remains

All code is committed and the branch builds + passes 8/8 tests at HEAD `05fedce`. Task 6 was finished (the missing `presentPersonPage` helper was added, commit `9f4cdfe`). A whole-branch review ran on Opus; its one Important finding was FIXED:
- `9f4cdfe` — Task 6 wiring
- `80230e6` — fix: don't auto-resume person page if playback was already paused (review Minor, promoted)
- `05fedce` — fix: resolve episode cast via SHOW tmdb id, not the episode's own guid (review Important — some Plex agents put a per-episode tmdb:// id in the episode Guid, which resolved wrong and silently dropped TMDB cast)

**Only remaining work: Task 7 simulator verification** (checklist below) then merge to main (local only; do not push until user says wrap up).

**Deferred follow-ups (review rated all non-blocking; NOT done):**
1. `TMDBClient.mergedEpisodeCast` — guests-vs-guests dedup gap + `$0.id ?? -1` sentinel; reviewer gave a clean rewrite using `Set(cast.compactMap(\.id))`. Cosmetic (dup row at worst, only on nil-id credits).
2. `tmdb-proxy` caches upstream 404/5xx for 7 days (pre-existing on ALL routes, not just episode_credits) — skip `cache.put` unless `upstreamResp.ok`.
3. `person.crop.circle` rail icon vs "Cast" label — `person.2` reads better for a list. **User's taste call.**

---

**Original state (now superseded — kept for context):** Tasks 1–5 of 7 done, committed, and review-approved; Task 6 was ~90% present but UNCOMMITTED and did not compile until the missing helper was added.

---

## What this is

P1 of the "Insights" feature: an X-Ray-style **cast panel** in the video player rail. TMDB credits primary (episode guest stars included), Plex Role fallback, Select on an actor deep-links to the existing Person detail page over paused playback.

Read these two documents before touching code:
- **Spec:** `Docs/superpowers/specs/2026-07-07-insights-panel-design.md` (P1 = cast only; trivia pipeline is P2, not this work)
- **Plan (7 tasks, checkbox steps, complete code):** `Docs/superpowers/plans/2026-07-07-insights-cast-panel-p1.md`

Process artifacts (briefs, implementer reports, review packages, progress ledger) live in `.superpowers/sdd/` — ledger: `.superpowers/sdd/progress.md` (this workstream's section is at the bottom).

## Branch & commit state

Branch: `feature/insights-cast-panel` (do NOT push to origin — user pushes when work is wrapped; committing locally is encouraged).

```
af0bf14 feat(insights): cast list panel content view (UpNext-pattern rows + focus pin)   [Task 5 ✓ reviewed]
2949e7a feat(insights): Cast rail button (hidden until cast loads)                       [Task 4 ✓ reviewed]
a9bb3e5 feat(insights): cast mapper + view-model insightsCast loader                     [Task 3 ✓ reviewed]
944cb51 feat(tmdb-cast): structured cast fetch with episode-level dedup                  [Task 2 ✓ reviewed]
70859c3 feat(tmdb-proxy): episode_credits route for per-episode cast + guest stars       [Task 1 ✓ reviewed]
320460f docs(insights): P1 implementation plan + spec alignment                          [base]
```

Task 1's worker route is **already deployed to production** (version 348c8ae1) and verified:
`curl "https://tmdb-proxy.baingurley.workers.dev/tmdb/episode_credits/1396?season=1&episode=1"` returns real cast+guest_stars JSON; missing `episode` param returns 400. No wrangler work remains.

## ⚠️ Working tree: partial Task 6 (uncommitted, does not build)

Task 6's implementer was interrupted. These edits ARE present and correct (verified against the plan):

1. `Rivulet/Views/Media/Person/UIKit/PersonDetailViewController.swift`: `var onDismiss: (() -> Void)?` added below `onSelectItem`; `viewWillDisappear` now fires `if isBeingDismissed { onDismiss?() }`.
2. `Rivulet/Views/Player/PlayerContainerViewController.swift`:
   - `insightsCastCache: [MediaPerson]` property added near `upNextEpisodesCache`.
   - `dismiss(animated:completion:)` override now begins with the critical guard: `if presentedViewController != nil { super.dismiss(...); return }` — this MUST stay first; without it the container's dismiss "priority ladder" swallows the person page's Menu dismissal.
   - Sinks added after the `$upNextEpisodes` sink: `vm.$insightsCast` → cache + `rail?.setInsightsAvailable(!cast.isEmpty)`; `vm.$itemGeneration` (removeDuplicates) → `Task { await vm?.loadInsightsCast() }`.
   - `rail.onInsights` closure added after `rail.onUpNext`, guarded on non-empty cache, presents `InsightsCastListView(cast:onSelect:)` at width 480 from `rail.insightsButton`.

**What is MISSING (the interrupted edit):** the `presentPersonPage(_:)` helper. `rail.onInsights`'s onSelect already calls `self?.presentPersonPage(person)`, so the project will not compile until you add it near `presentRailPanel` in `PlayerContainerViewController.swift`:

```swift
/// Cast row Select → person detail page over paused playback. The rail
/// panel is dismissed first (its focus fence would fight the presented
/// page), and playback resumes when the page is dismissed. Filmography
/// posters are intentionally inert from the player (onSelectItem unset)
/// — navigating to another title mid-playback is out of scope for P1.
private func presentPersonPage(_ person: MediaPerson) {
    guard let vm = viewModel else { return }
    activeRailPanel?.dismissPanel()
    vm.pause()
    let page = PersonDetailViewController(person: person)
    page.onDismiss = { [weak vm] in vm?.resume() }
    present(page, animated: true)
}
```

Then finish Task 6 per its brief (`.superpowers/sdd/task-6-brief.md`): build, run the two test suites, commit as
`feat(insights): wire Cast panel into player rail + person page deep link` (both modified files in one commit).

## Environment facts (non-negotiable)

- **Simulator UDID:** `33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3` (Apple TV 4K 3rd gen @1080p; was booted). Never use `generic/platform=tvOS`.
- **ALWAYS** pass `-derivedDataPath /tmp/rivulet-insights-dd` to xcodebuild (already warm). A bare xcodebuild corrupts the open Xcode's shared build DB (recovery: `killall XCBBuildService` + delete XCBuildData).
- Build: `xcodebuild -scheme Rivulet -destination "platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3" -derivedDataPath /tmp/rivulet-insights-dd build 2>&1 | tail -5`
- Tests: same command with `test -only-testing:RivuletTests/InsightsCastMapperTests -only-testing:RivuletTests/TMDBEpisodeCreditsTests` (6 tests total, all green as of af0bf14).
- tvOS UIKit work: consult the skill at `~/.claude/skills/rivulet-tvos-uikit/` (focus engine, Menu-press routing, Select-in-pressesBegan traps).

## Remaining work after Task 6

**Task 7 — simulator verification** (plan has the full 8-point checklist). Review-added checks:
- Visual render of cast rows + fallback person icon before/after headshot load.
- Focus pin lands on first row, then no bounce-back on a long scrolling cast list.
- Person page: pause on present, resume on Menu dismissal, no double-fire of `onDismiss`.
- Episode content should show guest stars after regulars (route is deployed, so this works live).
- Do NOT drive/screenshot the simulator while the user is actively using it — coordinate, or hand the checklist to the user.

**Final whole-branch review** (base `320460f` → HEAD) — accumulated Minor findings from per-task reviews to triage there (none are blocking; all recorded in `.superpowers/sdd/progress.md`):
- T2: only one test exercises JSON snake_case decoding of `guest_stars`; test names drifted from plan (behavior covered); guests-vs-guests dedup unscoped in `mergedEpisodeCast`; `$0.id ?? -1` sentinel could be `Set<Int?>`.
- T3: `"tmdb-person-\(name)"` id fallback can collide for same-named people when TMDB id is nil.
- T4: `person.crop.circle` icon vs "Cast" label semantics — design-taste call for the user (alternatives: `person.2`).

**Wrap-up:** merge/fast-forward to `main` locally but DO NOT push until the user says wrap up. The user prefers root-cause fixes over patches, and honest reporting of anything not verified.

## Data-flow recap (for orientation)

`UniversalPlayerViewModel.loadInsightsCast()` (triggered per item via `$itemGeneration` sink): resolves TMDB id via `metadata.tmdbId ?? metadata.parentShowTmdbId ?? metadata.showTmdbId` → episodes: `TMDBClient.episodeCastCredits(showTmdbId:season:episode:)` else `castCredits(tmdbId:type:)` → maps via `InsightsCastMapper.mediaPeople(fromTMDB:...)` → if empty, Plex fallback: item `Role`, then show `Role` via `getFullMetadata`, mapped with absolute-URL-safe `personThumbURL` → publishes `insightsCast: [MediaPerson]` guarded by `itemGeneration`. Container caches it, toggles rail button, presents `InsightsCastListView` on demand.
