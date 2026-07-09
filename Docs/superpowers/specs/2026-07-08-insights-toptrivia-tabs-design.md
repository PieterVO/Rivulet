# Insights Panel: Top 10 Trivia + Category Tabs — Design

**Date:** 2026-07-08
**Status:** Approved design, pre-implementation
**Revises:** `2026-07-07-insights-panel-design.md`'s single scrolling list (trivia rows then cast
rows in one `UIStackView`, shipped in `6ea014b`). That design worked for a handful of facts;
titles with 100+ facts (Ratatouille: 152) make one flat scroll impractical at TV viewing
distance.

---

## What changes

1. **Pipeline** (`insights-pipeline`, Python): the extraction LLM call gains a fifth field,
   `interest` (integer, 1–10), scoring how surprising/specific/non-generic a fact is. No new LLM
   call, no new pipeline stage — folded into the existing `extract.py` call per-fact, same
   reasoning as the existing `spoiler` field. `verify.py` does not touch it.
2. **Client** (Rivulet, Swift): the Insights panel's single flat list becomes a tabbed browser —
   a pill row (`Top 10 | Cast | Production | Casting | ...`) at the top of
   `InsightsPanelContainerView`, switching which filtered row-list is mounted below it. Existing
   row views, focus-scroll mechanics, and the cast→actor crossfade are all reused unchanged.

## Decisions

| Question | Decision |
|---|---|
| Where is interest scored? | Folded into `extract.py`'s existing per-fact LLM call (additive `interest` field), not a separate ranking stage. Cheapest option; extract model already reads each fact against its source, which is the same context needed to judge "is this fact interesting." |
| Score representation | `interest: Int` on the 1–10 scale (matches `spoiler`'s small-int style), not a boolean `isTopTen` flag — preserves the ability to re-tune the Top 10 cutoff without re-running the LLM. |
| Top 10 threshold | `interest >= 7`, capped at the 10 highest-scoring qualifying facts. Fewer than 10 qualifying facts → show fewer than 10 (no padding with mediocre filler). Zero qualifying facts → no Top 10 pill at all. |
| Category pill order | Unchanged from today: `Top 10`, `Cast`, then `TriviaCategory.allCases` declaration order (Production, Casting, Adaptation, Reference, Lore, Goof, Music, Other). A category pill is shown only if it has ≥1 visible fact after spoiler/suppression filtering. |
| Migration for already-published titles | Bump `PIPELINE_VERSION` 1→2 in `insights/config.py`. The existing staleness check (`is_stale`, exact `!=` match on `pipeline_version`) marks every previously-published title stale; the existing scheduled-refresh loop re-enqueues and republishes them with real `interest` scores over subsequent passes (bounded by the existing `scheduled_max_titles` cap — not instant for the whole catalog, but automatic). No manifest surgery, no manual R2 cleanup. |
| Client handling of missing `interest` | Additive optional field (`interest: Int?`). `nil` (old-schema titles not yet regenerated) is simply not eligible for Top 10 — that title just shows `Cast` + category pills until its next pipeline pass. No synthetic default score. |
| Cast/actor crossfade | Unchanged. Selecting a cast row still crossfades in place to `InsightsActorView`; this is orthogonal to which pill is active and pill state is preserved underneath. |
| Pill component | Reuse `SeasonPillView`'s established pattern (capsule shape, `isSelectedSeason`/`isFocusedPill` dual-state styling, focus-previews/select-commits interaction, host redirects focus to the selected pill on arrival) rather than inventing a new visual language — generalized into a new, panel-owned pill type since `SeasonPillView` itself is coupled to `MediaDetail`'s season-selection use case. |

## Architecture

### Pipeline side

```
insights/prompts/extract.txt   — schema gains "interest" (1-10) as a 5th required field
insights/stages/extract.py     — no code change beyond parsing the new field into Fact
insights/stages/verify.py      — unchanged; does not touch interest (same as spoiler)
insights/models.py             — Fact gains `interest: int` (required field going forward;
                                   old records without it deserialize as absent, not zero)
insights/config.py             — PIPELINE_VERSION = 1 → 2
```

The extraction prompt's existing "Schema" section (four fields today: `text`, `category`,
`spoiler`, `source`) gets a fifth bullet with explicit scoring guidance and both a low- and
high-scoring example, matching the existing prompt's style of concrete criteria per field (see
the `spoiler` field's 0/1/2 definitions for the pattern to match). Scoring guidance: a fact
scores high (8-10) when it's surprising, specific, or reveals something a general audience
wouldn't already assume; it scores low (1-3) when it's generic, expected, or the kind of detail
true of nearly any production (e.g. "the film had a director" tier of blandness). The prompt's
existing "THIN SOURCE, THIN OUTPUT" rule already discourages padding — the same spirit extends to
not inflating scores to make output feel more valuable.

### Client side

```
PlayerContainerViewController.rail.onInsights
        │  (unchanged call site: cast, trivia, suppressedTriviaIDs, hideSpoilers)
        ▼
InsightsPanelContainerView                          (MODIFIED)
        ├── InsightsTabBarView                       (NEW — pill row, mirrors SeasonPillView)
        ├── InsightsCastListView                      (MODIFIED — becomes tab-scoped)
        │       └── shows rows for the ACTIVE tab only, not all rows always
        └── InsightsActorView                         (state .actor — UNCHANGED)
```

- `InsightsPanelContainerView` gains a `selectedTab: InsightsTab` (`.topTen`, `.cast`,
  `.category(TriviaCategory)`) alongside its existing `state: {.list, .actor}`. The tab bar is
  only visible in `.list` state (hidden during the actor crossfade, matching how the cast list
  itself is hidden there today).
- `InsightsTabBarView` computes its available tabs once from the panel's `cast`/`trivia` inputs
  at construction (same inputs already passed into `InsightsCastListView` today): `.topTen` iff
  ≥1 fact scores ≥7, `.cast` iff cast is non-empty, one `.category` pill per `TriviaCategory` with
  ≥1 visible fact. Selecting a pill calls back into the container, which re-filters and hands a
  new row list to `InsightsCastListView`.
- `InsightsCastListView` keeps its existing `UIScrollView` + `UIStackView` + `focusableRows`
  machinery (untouched — this is what the trivia-row `intrinsicContentSize` fix from this
  session's earlier work already made sound). What changes is *which* rows get built into the
  stack: instead of always building trivia-then-cast in one pass, it exposes a
  `setRows(_ rows: [InsightsRow])` entry point the container calls on tab change, rebuilding the
  stack's arranged subviews from just that tab's filtered/sorted facts (or cast list, for `.cast`).
  Row types (`InsightsTriviaRowView`, `InsightsCastRowButton`) are unchanged.
- Switching tabs resets scroll position to top and re-runs the existing pin-first-focus-then-free
  landing behavior (mirrors how `UpNextListView` already lands focus on reload).
- `TriviaFact` gains `let interest: Int?` (Codable, optional, decodes missing key as `nil` — not
  a decode failure, since old published JSON won't have this key at all).
- `TitleTrivia` gains a computed `topTenFacts(hideSpoilers:suppressed:) -> [TriviaFact]`:
  filters through the existing `visibleFacts` logic, then filters `interest ?? 0 >= 7`, sorts
  descending by `interest`, caps at 10.

## Error handling

- Missing `interest` on a fact (old-schema data): treated as ineligible for Top 10, fully visible
  under its category pill as today. No user-facing error state — this resolves itself silently as
  titles get re-generated.
- Zero facts qualify for Top 10: no `.topTen` pill offered; panel opens directly to `Cast` (or the
  first available category pill if cast is also empty) — same fallback logic
  `insightsButtonShouldBeAvailable` already uses today to decide whether the rail button itself
  shows.
- A category becomes empty after spoiler/suppression filtering changes at runtime (e.g. user
  toggles "hide spoilers" while the panel is open): that pill is removed and, if it was the
  active tab, selection falls back to `Cast` or the next available pill.

## Testing

- `TriviaFact`/`TitleTrivia` decode tests: a fact JSON blob without an `interest` key decodes
  `interest == nil`, not a throw; `topTenFacts` correctly filters/sorts/caps a mixed-score fixture
  including facts at the `interest == nil` and `interest == 7` boundary.
- `InsightsTabBarView` unit tests: tab set derivation from a variety of cast/trivia input
  combinations (empty cast, single category, all categories, zero Top 10 qualifiers).
- Manual sim verification: Ratatouille (once re-generated under `PIPELINE_VERSION = 2`) shows a
  populated Top 10 tab plus multiple category pills; an un-regenerated title shows Cast +
  categories only, no Top 10 pill, no crash.
