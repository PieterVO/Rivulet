# Insights Panel: Top 10 Trivia + Category Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an LLM-scored `interest` field to the trivia pipeline and restructure the client's
Insights panel from one flat scrolling list into a pill-tab browser (`Top 10 | Cast | Production |
Casting | ...`).

**Architecture:** The pipeline (`insights-pipeline`, Python) adds a 5th field to its existing
per-fact extraction LLM call — no new stage, no new call. `PIPELINE_VERSION` bumps from 1 to 2 so
the existing staleness check re-enqueues every already-published title automatically. The client
(Rivulet, Swift) adds an optional `interest: Int?` to `TriviaFact`, a `topTenFacts` query on
`TitleTrivia`, a new `InsightsTabBarView` (generalizing `SeasonPillView`'s capsule/focus pattern),
and reworks `InsightsCastListView` to render only the active tab's rows instead of always
combining trivia+cast in one stack.

**Tech Stack:** Python 3.14 (pipeline, pytest), Swift 6 / UIKit / XCTest (client, tvOS 26+).

## Global Constraints

- Interest score: integer 1–10, folded into `extract.py`'s existing per-fact LLM call (no new
  pipeline stage, no new LLM call).
- Top 10 threshold: `interest >= 7`, capped at the 10 highest-scoring qualifying facts; fewer than
  10 qualifying facts shows fewer than 10; zero qualifying facts means no Top 10 pill at all.
- Category pill order: `Top 10`, `Cast`, then `TriviaCategory.allCases` declaration order
  (production, casting, adaptation, reference, lore, goof, music, other). A category pill appears
  only if it has ≥1 visible fact after spoiler/suppression filtering.
- Migration: bump `PIPELINE_VERSION` 1→2 in `insights/config.py`. No manifest surgery, no manual
  R2 cleanup — the existing staleness check and scheduled-refresh loop handle re-publishing.
- Missing `interest` on a fact (old-schema data) is treated as not eligible for Top 10 — no
  synthetic default score.
- `verify.py` does not touch `interest` (same reasoning as `spoiler`: the extract model's holistic
  read against the source is more reliable than a second isolated pass).
- Reuse `SeasonPillView`'s established visual/interaction pattern (capsule shape,
  `isSelectedSeason`/`isFocusedPill` dual-state styling, focus-previews/select-commits) for the
  new tab bar rather than inventing a new visual language.
- Existing cast→actor crossfade behavior in `InsightsPanelContainerView` is unchanged; tab
  selection is orthogonal to it and is preserved underneath the actor crossfade.
- tvOS focus rule (per the rivulet-tvos-uikit skill): rows in a scrollable list must be
  `isScrollEnabled = false` with self-driven `contentOffset`, and any row that needs to be
  reachable by focus-driven scroll must be focusable — this pattern is already correct in
  `InsightsCastListView`/`InsightsTriviaRowView`/`InsightsCastRowButton` and must not regress.

---

## Task 1: Pipeline — add `interest` to the Fact schema and extraction prompt

**Files:**
- Modify: `insights-pipeline/insights/models.py` (the `Fact` dataclass, ~line 51-95)
- Modify: `insights-pipeline/insights/prompts/extract.txt` (schema section)
- Modify: `insights-pipeline/insights/stages/extract.py` (`raw_fact_to_fact`, ~line 65-87)
- Modify: `insights-pipeline/insights/config.py` (`PIPELINE_VERSION`, line 13)
- Test: `insights-pipeline/tests/test_extract.py`
- Test: `insights-pipeline/tests/test_models.py` (create if it does not already exist — check
  first with `ls insights-pipeline/tests/test_models.py`)

**Interfaces:**
- Produces: `Fact.interest: int` (default `0`, keyword-compatible with existing positional test
  constructions like `Fact("text", "production", 0, source, source_snippet="s")`).
- Produces: `Fact.to_published_dict()` includes `"interest"` in its output dict.
- Produces: `raw_fact_to_fact(raw, source, source_snippet)` validates and carries through
  `interest` from the LLM's raw dict, defaulting to `0` if missing/invalid rather than rejecting
  the whole fact (matching the file's existing "extract stays permissive" philosophy for spoiler/
  category).

- [ ] **Step 1: Write the failing test for the Fact dataclass `interest` field**

Check whether `insights-pipeline/tests/test_models.py` exists:

```bash
ls "/Users/bain/git/Swift Projects/Rivulet/insights-pipeline/tests/test_models.py"
```

If it does not exist, create it with this content. If it exists, append the two test functions
below to it (keep any existing content in the file).

```python
"""Tests for insights.models: Fact/TitleTrivia dataclasses and pure helpers."""

from __future__ import annotations

from insights.models import Fact, Source


def test_fact_interest_defaults_to_zero_when_not_specified() -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    fact = Fact(text="A fact.", category="production", spoiler=0, source=source)
    assert fact.interest == 0


def test_fact_to_published_dict_includes_interest() -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    fact = Fact(text="A fact.", category="production", spoiler=0, source=source, interest=8)
    published = fact.to_published_dict()
    assert published["interest"] == 8
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet/insights-pipeline" && .venv/bin/pytest tests/test_models.py -v
```

Expected: FAIL — `TypeError: Fact.__init__() got an unexpected keyword argument 'interest'` (or
`AttributeError: 'Fact' object has no attribute 'interest'` if the file already existed with
other passing tests).

- [ ] **Step 3: Add `interest` to the `Fact` dataclass**

In `insights-pipeline/insights/models.py`, find the `Fact` dataclass (search for `class Fact:`).
It currently reads:

```python
@dataclass(slots=True)
class Fact:
    text: str
    category: str
    spoiler: int
    source: Source
    # Retained only through verify; NOT published. The exact source
    # sentence(s) the fact was extracted from, for the verify re-check.
    source_snippet: str = ""
```

Add `interest` as a new field after `source_snippet`, with a default of `0` so existing positional
constructions (`Fact("text", "category", 0, source)`) continue to work unchanged:

```python
@dataclass(slots=True)
class Fact:
    text: str
    category: str
    spoiler: int
    source: Source
    # Retained only through verify; NOT published. The exact source
    # sentence(s) the fact was extracted from, for the verify re-check.
    source_snippet: str = ""
    # How surprising/specific/non-interesting this fact is, 1-10, scored by
    # the extract LLM in the same call as category/spoiler. 0 = not scored
    # (old-schema data, or a value the LLM omitted/gave out of range) —
    # distinct from a real low score of 1, and never eligible for Top 10.
    interest: int = 0
```

Now find `to_published_dict` on the same class (search for `def to_published_dict`) — it
currently reads:

```python
    def to_published_dict(self) -> dict[str, Any]:
        """Client-facing shape — source_snippet stripped."""
        return {
            "id": self.id,
            "text": self.text,
            "category": self.category,
            "spoiler": self.spoiler,
            "source": self.source.to_dict(),
        }
```

Add `"interest"` to the returned dict:

```python
    def to_published_dict(self) -> dict[str, Any]:
        """Client-facing shape — source_snippet stripped."""
        return {
            "id": self.id,
            "text": self.text,
            "category": self.category,
            "spoiler": self.spoiler,
            "source": self.source.to_dict(),
            "interest": self.interest,
        }
```

Now find `to_working_dict` and `from_working_dict` on the same class — `to_working_dict` calls
`to_published_dict()` and adds `source_snippet`, so it picks up `interest` automatically with no
change needed. `from_working_dict` currently reads:

```python
    @classmethod
    def from_working_dict(cls, d: dict[str, Any]) -> "Fact":
        return cls(
            text=d["text"],
            category=d["category"],
            spoiler=int(d["spoiler"]),
            source=Source.from_dict(d["source"]),
            source_snippet=d.get("source_snippet", ""),
        )
```

Add `interest`, defaulting to `0` if the working dict predates this field (resumable
`facts_raw.jsonl` files from before this change):

```python
    @classmethod
    def from_working_dict(cls, d: dict[str, Any]) -> "Fact":
        return cls(
            text=d["text"],
            category=d["category"],
            spoiler=int(d["spoiler"]),
            source=Source.from_dict(d["source"]),
            source_snippet=d.get("source_snippet", ""),
            interest=int(d.get("interest", 0)),
        )
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet/insights-pipeline" && .venv/bin/pytest tests/test_models.py -v
```

Expected: PASS (2 passed).

- [ ] **Step 5: Write the failing test for `raw_fact_to_fact` carrying through `interest`**

Append these two test functions to `insights-pipeline/tests/test_extract.py` (after
`test_raw_fact_to_fact_rejects_non_dict`, before `test_extract_section_maps_llm_facts_and_attaches_snippet`):

```python
def test_raw_fact_to_fact_carries_through_valid_interest() -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    raw = {"text": "A fact.", "category": "production", "spoiler": 0, "source": "X", "interest": 8}
    fact = raw_fact_to_fact(raw, source, "s")
    assert fact is not None
    assert fact.interest == 8


def test_raw_fact_to_fact_defaults_interest_to_zero_when_missing_or_invalid() -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    # Missing entirely.
    missing = {"text": "A fact.", "category": "production", "spoiler": 0, "source": "X"}
    fact = raw_fact_to_fact(missing, source, "s")
    assert fact is not None
    assert fact.interest == 0
    # Out of the documented 1-10 range — permissive extract stage does not
    # reject the whole fact for a bad interest value, it just zeroes it.
    out_of_range = {"text": "A fact.", "category": "production", "spoiler": 0, "source": "X", "interest": 99}
    fact2 = raw_fact_to_fact(out_of_range, source, "s")
    assert fact2 is not None
    assert fact2.interest == 0
```

- [ ] **Step 6: Run the test to verify it fails**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet/insights-pipeline" && .venv/bin/pytest tests/test_extract.py -v -k interest
```

Expected: FAIL — `AssertionError: assert 0 == 8` (raw_fact_to_fact does not read `interest` yet).

- [ ] **Step 7: Update `raw_fact_to_fact` to carry through `interest`**

In `insights-pipeline/insights/stages/extract.py`, find `raw_fact_to_fact` — it currently reads:

```python
def raw_fact_to_fact(raw: object, source: Source, source_snippet: str) -> Fact | None:
    """Pure: validate+map one LLM-returned dict to a Fact, or None if unusable.

    Defensive against the model not perfectly following the schema (missing
    field, wrong type, category/spoiler outside the enum, empty text) —
    extract stays permissive here (never crashes a batch on one bad
    entry); it's verify's job to be the strict gate.
    """
    if not isinstance(raw, dict):
        return None

    text = raw.get("text")
    if not isinstance(text, str) or not text.strip():
        return None

    category = raw.get("category")
    if category not in CATEGORIES:
        return None

    spoiler = raw.get("spoiler")
    if isinstance(spoiler, str) and spoiler.isdigit():
        spoiler = int(spoiler)
    if spoiler not in SPOILER_LEVELS:
        return None

    return Fact(
        text=text.strip(),
        category=category,
        spoiler=spoiler,
        source=source,
        source_snippet=source_snippet,
    )
```

Replace it with a version that also reads and validates `interest`, defaulting to `0` (not
rejecting the fact) on any missing/malformed/out-of-range value — matching the existing permissive
philosophy for this stage:

```python
def raw_fact_to_fact(raw: object, source: Source, source_snippet: str) -> Fact | None:
    """Pure: validate+map one LLM-returned dict to a Fact, or None if unusable.

    Defensive against the model not perfectly following the schema (missing
    field, wrong type, category/spoiler outside the enum, empty text) —
    extract stays permissive here (never crashes a batch on one bad
    entry); it's verify's job to be the strict gate. `interest` is even
    more permissive than category/spoiler: a missing or out-of-range value
    zeroes the field (never eligible for Top 10) rather than dropping the
    whole fact, since a bad interest score is not a sign the FACT itself is
    unusable.
    """
    if not isinstance(raw, dict):
        return None

    text = raw.get("text")
    if not isinstance(text, str) or not text.strip():
        return None

    category = raw.get("category")
    if category not in CATEGORIES:
        return None

    spoiler = raw.get("spoiler")
    if isinstance(spoiler, str) and spoiler.isdigit():
        spoiler = int(spoiler)
    if spoiler not in SPOILER_LEVELS:
        return None

    interest = raw.get("interest", 0)
    if isinstance(interest, str) and interest.isdigit():
        interest = int(interest)
    if not isinstance(interest, int) or not (1 <= interest <= 10):
        interest = 0

    return Fact(
        text=text.strip(),
        category=category,
        spoiler=spoiler,
        source=source,
        source_snippet=source_snippet,
        interest=interest,
    )
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet/insights-pipeline" && .venv/bin/pytest tests/test_extract.py tests/test_models.py -v
```

Expected: all PASS, including the pre-existing tests in `test_extract.py` (this change must not
break `test_raw_fact_to_fact_valid`, which constructs a `Fact` without `interest` — confirm that
test's `assert fact == Fact(...)` comparison still passes, since both sides now default `interest`
to `0`).

- [ ] **Step 9: Update the extraction prompt's schema section**

In `insights-pipeline/insights/prompts/extract.txt`, find the `## Schema` section. It currently
ends with the `source` field description followed by the `## Output example` section:

```
- `"source"` (string): a short label for where in the text this came from — reuse the section
  name if the text has one (e.g. "Production", "Casting", "Plot", "Reception"), or `"general"` if
  the text has no clear section structure.

## Output example (format only — do not reuse this content)

[
  {"text": "The director shot the corridor fight practically using a rotating set rather than CGI.", "category": "production", "spoiler": 0, "source": "Production"},
  {"text": "The lead actor was cast before the screenplay was finished.", "category": "casting", "spoiler": 0, "source": "Casting"}
]

Now extract facts from the excerpt the user provides. Output ONLY the JSON array.
```

Replace this whole block with a version that adds `interest` as a fifth schema field with
explicit scoring criteria and two examples spanning the range:

```
- `"source"` (string): a short label for where in the text this came from — reuse the section
  name if the text has one (e.g. "Production", "Casting", "Plot", "Reception"), or `"general"` if
  the text has no clear section structure.
- `"interest"` (integer, 1-10): how surprising, specific, or non-generic this fact is to someone
  who already knows the basic premise of the work.
  - `8-10` — genuinely surprising, unusual, or specific: an unexpected behind-the-scenes decision,
    a striking coincidence, a detail most fans would not already assume.
  - `4-7` — a solid, concrete fact that is worth knowing but not surprising: normal casting/
    production detail, a specific but expected connection to the source material.
  - `1-3` — generic or expected: the kind of detail true of nearly any production (e.g. "the film
    had a director," "the show was filmed over several months" with no specific or unusual detail
    attached). Do not inflate a score just to make the output feel more valuable — the same
    honesty rule as fact selection itself: a low score is correct when a fact is genuinely
    unremarkable.

## Output example (format only — do not reuse this content)

[
  {"text": "The director shot the corridor fight practically using a rotating set rather than CGI.", "category": "production", "spoiler": 0, "source": "Production", "interest": 8},
  {"text": "The lead actor was cast before the screenplay was finished.", "category": "casting", "spoiler": 0, "source": "Casting", "interest": 3}
]

Now extract facts from the excerpt the user provides. Output ONLY the JSON array.
```

Also update the `## Schema` intro line just above the field list, which currently reads:

```
Each array entry is a JSON object with exactly these four fields:
```

Change `four` to `five`:

```
Each array entry is a JSON object with exactly these five fields:
```

- [ ] **Step 10: Run the prompt-loads test to verify it still passes**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet/insights-pipeline" && .venv/bin/pytest tests/test_extract.py -v -k test_prompt_file_exists_and_loads
```

Expected: PASS.

- [ ] **Step 11: Sync the bake-off source-of-record prompt copy**

The file header of `insights-pipeline/insights/prompts/extract.txt` notes it is bundled from
`bakeoff/prompts/extract_v1.txt` (the source of record). Apply the identical schema-section edit
from Step 9 to that file:

```bash
diff "/Users/bain/git/Swift Projects/Rivulet/insights-pipeline/insights/prompts/extract.txt" "/Users/bain/git/Swift Projects/Rivulet/insights-pipeline/bakeoff/prompts/extract_v1.txt"
```

Run this diff first to see what (if anything) already differs between the two copies before
editing — apply the same `interest` field addition to `bakeoff/prompts/extract_v1.txt`, preserving
any other existing differences between the two files untouched.

- [ ] **Step 12: Bump `PIPELINE_VERSION`**

In `insights-pipeline/insights/config.py`, find line 13:

```python
PIPELINE_VERSION = 1
```

Change to:

```python
PIPELINE_VERSION = 2
```

- [ ] **Step 13: Run the full pipeline test suite**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet/insights-pipeline" && .venv/bin/pytest -v
```

Expected: all PASS. Pay particular attention to any test asserting a literal `pipeline_version`
value or a literal published-dict field count/shape (e.g. in `tests/test_publish.py` or
`tests/test_seed.py`, if such assertions exist) — a test hardcoding `PIPELINE_VERSION == 1` or an
exact published-dict equality without `interest` will need updating to match. If any such test
fails, update its expected value/dict to match the new version number or the new `interest` field
in the published dict shape — do not change the test's intent, only the literal values it
compares against.

- [ ] **Step 14: Commit**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && git add insights-pipeline/insights/models.py insights-pipeline/insights/stages/extract.py insights-pipeline/insights/prompts/extract.txt insights-pipeline/bakeoff/prompts/extract_v1.txt insights-pipeline/insights/config.py insights-pipeline/tests/test_extract.py insights-pipeline/tests/test_models.py
git commit -m "$(cat <<'EOF'
feat(insights-pipeline): score trivia facts 1-10 for interest, bump schema v2

Folds an "interest" field into the existing extract.py LLM call (no new
stage, no new call) so the client can surface a curated Top 10 alongside
the full category-browsable list. PIPELINE_VERSION 1->2 triggers the
existing staleness check to re-enqueue and republish every previously
generated title with real scores via the normal scheduled-refresh loop.
EOF
)"
```

---

## Task 2: Client — add `interest` to `TriviaFact` and a `topTenFacts` query

**Files:**
- Modify: `Rivulet/Models/Insights/TriviaFact.swift`
- Test: `RivuletTests/Unit/TriviaFactTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 (independent schema; the client already tolerates unknown/missing
  additive fields per its existing `try?`-based decode pattern).
- Produces: `TriviaFact.interest: Int?` (nil when absent from JSON — not a decode failure).
- Produces: `TitleTrivia.topTenFacts(hideSpoilers: Bool, suppressed: Set<String>) -> [TriviaFact]`
  — filters through the same visibility rules as `visibleFacts`, keeps only facts with
  `interest != nil && interest! >= 7`, sorts descending by `interest`, caps at 10.

- [ ] **Step 1: Write the failing tests**

Add these test functions to `RivuletTests/Unit/TriviaFactTests.swift`, after
`testVisibleFactsOrderedByCategory` (the last existing test in the file):

```swift
    // MARK: - interest / topTenFacts

    private let payloadWithInterest = """
    {
      "id": "tmdb://27205",
      "type": "movie",
      "generatedAt": "2026-07-07T00:00:00Z",
      "pipelineVersion": 2,
      "attribution": [ { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } ],
      "facts": [
        { "id": "f_high1", "text": "Highest interest fact.",
          "category": "production", "spoiler": 0, "interest": 10,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } },
        { "id": "f_high2", "text": "Second highest interest fact.",
          "category": "casting", "spoiler": 0, "interest": 9,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } },
        { "id": "f_borderline", "text": "Borderline interest fact.",
          "category": "reference", "spoiler": 0, "interest": 7,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } },
        { "id": "f_low", "text": "Low interest fact.",
          "category": "goof", "spoiler": 0, "interest": 3,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } },
        { "id": "f_nointerest", "text": "No interest field at all (old-schema fact).",
          "category": "lore", "spoiler": 0,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } },
        { "id": "f_spoiler_high", "text": "High interest but a spoiler.",
          "category": "production", "spoiler": 1, "interest": 10,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } }
      ]
    }
    """.data(using: .utf8)!

    func testMissingInterestFieldDecodesAsNilNotAThrow() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let noInterestFact = trivia.facts.first { $0.id == "f_nointerest" }
        XCTAssertNotNil(noInterestFact, "decode must not throw or drop the fact")
        XCTAssertNil(noInterestFact?.interest)
    }

    func testInterestFieldDecodesPresentValue() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let highFact = trivia.facts.first { $0.id == "f_high1" }
        XCTAssertEqual(highFact?.interest, 10)
    }

    func testTopTenFactsExcludesNilAndBelowThresholdInterest() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let topTen = trivia.topTenFacts(hideSpoilers: true, suppressed: [])
        let ids = topTen.map(\.id)
        XCTAssertFalse(ids.contains("f_low"), "interest 3 is below the >=7 threshold")
        XCTAssertFalse(ids.contains("f_nointerest"), "nil interest is never eligible for Top 10")
    }

    func testTopTenFactsRespectsHideSpoilers() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let topTenHidden = trivia.topTenFacts(hideSpoilers: true, suppressed: [])
        XCTAssertFalse(topTenHidden.map(\.id).contains("f_spoiler_high"), "spoiler facts must be excluded when hideSpoilers is true, even at interest 10")

        let topTenShown = trivia.topTenFacts(hideSpoilers: false, suppressed: [])
        XCTAssertTrue(topTenShown.map(\.id).contains("f_spoiler_high"))
    }

    func testTopTenFactsSortedDescendingByInterest() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let topTen = trivia.topTenFacts(hideSpoilers: true, suppressed: [])
        let scores = topTen.map { $0.interest ?? 0 }
        XCTAssertEqual(scores, scores.sorted(by: >), "must be sorted descending by interest")
        XCTAssertEqual(topTen.first?.id, "f_high1")
    }

    func testTopTenFactsCapsAtTen() throws {
        let manyHighFactsJSON = """
        {
          "id": "tmdb://1", "type": "movie", "generatedAt": "", "pipelineVersion": 2,
          "attribution": [],
          "facts": [
            \((1...15).map { "{ \"id\": \"f_\($0)\", \"text\": \"Fact \($0).\", \"category\": \"production\", \"spoiler\": 0, \"interest\": 8, \"source\": { \"name\": \"Wikipedia\", \"url\": \"https://w/x\" } }" }.joined(separator: ",\n"))
          ]
        }
        """.data(using: .utf8)!
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: manyHighFactsJSON)
        let topTen = trivia.topTenFacts(hideSpoilers: true, suppressed: [])
        XCTAssertEqual(topTen.count, 10, "15 qualifying facts must cap at 10")
    }

    func testTopTenFactsReturnsFewerThanTenWhenFewQualify() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let topTen = trivia.topTenFacts(hideSpoilers: true, suppressed: [])
        // Only f_high1 (10), f_high2 (9), f_borderline (7) qualify with hideSpoilers=true.
        XCTAssertEqual(topTen.count, 3)
    }

    func testTopTenFactsRespectsSuppression() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let topTen = trivia.topTenFacts(hideSpoilers: true, suppressed: ["f_high1"])
        XCTAssertFalse(topTen.map(\.id).contains("f_high1"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild test -scheme Rivulet -destination "platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3" -only-testing:RivuletTests/TriviaFactTests 2>&1 | tail -60
```

Expected: FAIL to compile — `interest` is not a member of `TriviaFact`, and `topTenFacts` is not a
member of `TitleTrivia`.

- [ ] **Step 3: Add `interest` to `TriviaFact` and `topTenFacts` to `TitleTrivia`**

In `Rivulet/Models/Insights/TriviaFact.swift`, find the `TriviaFact` struct's `init(from
decoder:)`. It currently reads:

```swift
nonisolated struct TriviaFact: Codable, Identifiable, Sendable, Hashable {
    /// Stable id (pipeline: hash of text+source.url). The report/suppress key.
    let id: String
    let text: String
    let category: TriviaCategory
    /// 0 = no spoiler · 1 = this title's plot · 2 = later episodes/seasons.
    let spoiler: Int
    let source: TriviaSource

    enum CodingKeys: String, CodingKey {
        case id, text, category, spoiler, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        // Unknown categories degrade to `.other` rather than failing the whole
        // payload — the store's category enum may grow ahead of the client.
        category = (try? c.decode(TriviaCategory.self, forKey: .category)) ?? .other
        // Fail CLOSED on a missing/malformed spoiler tag: default to the
        // highest level (2) so a corrupt payload hides the fact under the
        // hide-spoilers toggle rather than leaking it over the user's video.
        // The pipeline always emits a valid 0/1/2; this guards R2 corruption
        // or a future schema change, where showing-by-default is the wrong risk.
        spoiler = (try? c.decode(Int.self, forKey: .spoiler)) ?? 2
        source = try c.decode(TriviaSource.self, forKey: .source)
    }
}
```

Replace with a version adding `interest: Int?`:

```swift
nonisolated struct TriviaFact: Codable, Identifiable, Sendable, Hashable {
    /// Stable id (pipeline: hash of text+source.url). The report/suppress key.
    let id: String
    let text: String
    let category: TriviaCategory
    /// 0 = no spoiler · 1 = this title's plot · 2 = later episodes/seasons.
    let spoiler: Int
    let source: TriviaSource
    /// How interesting this fact is, 1-10, scored by the pipeline's extraction
    /// LLM. `nil` when absent (facts published before this field existed) —
    /// distinct from a real low score, and never eligible for the Top 10 tab.
    let interest: Int?

    enum CodingKeys: String, CodingKey {
        case id, text, category, spoiler, source, interest
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        // Unknown categories degrade to `.other` rather than failing the whole
        // payload — the store's category enum may grow ahead of the client.
        category = (try? c.decode(TriviaCategory.self, forKey: .category)) ?? .other
        // Fail CLOSED on a missing/malformed spoiler tag: default to the
        // highest level (2) so a corrupt payload hides the fact under the
        // hide-spoilers toggle rather than leaking it over the user's video.
        // The pipeline always emits a valid 0/1/2; this guards R2 corruption
        // or a future schema change, where showing-by-default is the wrong risk.
        spoiler = (try? c.decode(Int.self, forKey: .spoiler)) ?? 2
        source = try c.decode(TriviaSource.self, forKey: .source)
        interest = try? c.decode(Int.self, forKey: .interest)
    }
}
```

Now find the `visibleFacts` extension at the bottom of the file:

```swift
extension TitleTrivia {
    /// Facts to display, honoring the user's hide-spoilers preference and the
    /// server-served suppression list, ordered by category (display order).
    ///
    /// - `hideSpoilers`: when true, drop any fact with `spoiler >= 1`. Without
    ///   playhead sync we can't know what the viewer has passed, so this-title
    ///   plot facts (level 1) are treated as spoilers too.
    /// - `suppressed`: fact ids the Worker reports as auto-hidden (report
    ///   threshold crossed). Always dropped regardless of the toggle.
    func visibleFacts(hideSpoilers: Bool, suppressed: Set<String>) -> [TriviaFact] {
        facts
            .filter { !suppressed.contains($0.id) }
            .filter { hideSpoilers ? $0.spoiler == 0 : true }
            .sorted { lhs, rhs in
                let li = TriviaCategory.allCases.firstIndex(of: lhs.category) ?? Int.max
                let ri = TriviaCategory.allCases.firstIndex(of: rhs.category) ?? Int.max
                return li < ri
            }
    }
}
```

Add a new `topTenFacts` method to this same extension:

```swift
extension TitleTrivia {
    /// Facts to display, honoring the user's hide-spoilers preference and the
    /// server-served suppression list, ordered by category (display order).
    ///
    /// - `hideSpoilers`: when true, drop any fact with `spoiler >= 1`. Without
    ///   playhead sync we can't know what the viewer has passed, so this-title
    ///   plot facts (level 1) are treated as spoilers too.
    /// - `suppressed`: fact ids the Worker reports as auto-hidden (report
    ///   threshold crossed). Always dropped regardless of the toggle.
    func visibleFacts(hideSpoilers: Bool, suppressed: Set<String>) -> [TriviaFact] {
        facts
            .filter { !suppressed.contains($0.id) }
            .filter { hideSpoilers ? $0.spoiler == 0 : true }
            .sorted { lhs, rhs in
                let li = TriviaCategory.allCases.firstIndex(of: lhs.category) ?? Int.max
                let ri = TriviaCategory.allCases.firstIndex(of: rhs.category) ?? Int.max
                return li < ri
            }
    }

    /// The curated "Top 10" tab: facts scoring >= 7 interest, sorted highest
    /// first, capped at 10. A `nil` interest (old-schema fact, not yet
    /// regenerated under the scoring pipeline) is never eligible — no
    /// synthetic default score. Same visibility filtering (spoilers,
    /// suppression) as `visibleFacts`, since a fact hidden from the category
    /// tabs must also be hidden from Top 10.
    func topTenFacts(hideSpoilers: Bool, suppressed: Set<String>) -> [TriviaFact] {
        visibleFacts(hideSpoilers: hideSpoilers, suppressed: suppressed)
            .filter { ($0.interest ?? 0) >= 7 }
            .sorted { ($0.interest ?? 0) > ($1.interest ?? 0) }
            .prefix(10)
            .map { $0 }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild test -scheme Rivulet -destination "platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3" -only-testing:RivuletTests/TriviaFactTests 2>&1 | tail -60
```

Expected: all PASS, including the pre-existing tests in this file (confirm
`testDecodesPayloadAndUnknownCategoryDegradesToOther` and the others still pass — this change is
purely additive to the struct).

- [ ] **Step 5: Commit**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && git add Rivulet/Models/Insights/TriviaFact.swift RivuletTests/Unit/TriviaFactTests.swift
git commit -m "$(cat <<'EOF'
feat(insights): TriviaFact.interest + TitleTrivia.topTenFacts

Additive optional field (nil for facts published before scoring existed —
never eligible for Top 10, no synthetic default). topTenFacts filters
through the existing visibility rules, keeps interest >= 7, sorts
descending, caps at 10.
EOF
)"
```

---

## Task 3: Client — `InsightsTabBarView` (pill tab bar component)

**Files:**
- Create: `Rivulet/Views/Player/UIKit/InsightsTabBarView.swift`
- Test: `RivuletTests/Unit/InsightsTabBarViewTests.swift`

**Interfaces:**
- Consumes: `TriviaCategory` (from `Rivulet/Models/Insights/TriviaFact.swift`, existing).
- Produces:
  ```swift
  enum InsightsTab: Hashable {
      case topTen
      case cast
      case category(TriviaCategory)
  }

  final class InsightsTabBarView: UIView {
      var onSelect: ((InsightsTab) -> Void)?

      init(tabs: [InsightsTab], selected: InsightsTab)
      func setSelected(_ tab: InsightsTab)

      static func availableTabs(
          cast: [MediaPerson],
          trivia: TitleTrivia?,
          suppressedTriviaIDs: Set<String>,
          hideSpoilers: Bool
      ) -> [InsightsTab]

      static func title(for tab: InsightsTab) -> String
  }
  ```
  `availableTabs` is a pure static function (no UIKit dependency in its logic) so it is directly
  unit-testable without instantiating a view. `title(for:)` maps `.topTen` → `"Top 10"`, `.cast` →
  `"Cast"`, `.category(let c)` → the existing `TriviaCategory.displayName` values currently private
  to `PlayerInsightsPanelView.swift` (Task 4 makes this shared — see Task 4 Step 1).

- [ ] **Step 1: Write the failing tests for `availableTabs`**

Create `RivuletTests/Unit/InsightsTabBarViewTests.swift`:

```swift
//
//  InsightsTabBarViewTests.swift
//  RivuletTests
//
//  Tab-set derivation for the Insights panel's pill bar — pure logic, no
//  view instantiation needed.
//

import XCTest
@testable import Rivulet

final class InsightsTabBarViewTests: XCTestCase {

    private func fact(id: String, category: TriviaCategory, spoiler: Int = 0, interest: Int? = nil) -> TriviaFact {
        let json = """
        { "id": "\(id)", "text": "Fact text.", "category": "\(category.rawValue)", "spoiler": \(spoiler),
          \(interest.map { "\"interest\": \($0)," } ?? "")
          "source": { "name": "Wikipedia", "url": "https://w/x" } }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TriviaFact.self, from: json)
    }

    private func trivia(facts: [TriviaFact]) -> TitleTrivia {
        let factsJSON = try! JSONEncoder().encode(facts)
        let factsString = String(data: factsJSON, encoding: .utf8)!
        let json = """
        { "id": "tmdb://1", "type": "movie", "generatedAt": "", "pipelineVersion": 2,
          "attribution": [], "facts": \(factsString) }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TitleTrivia.self, from: json)
    }

    func testNoCastNoTriviaYieldsNoTabs() {
        let tabs = InsightsTabBarView.availableTabs(cast: [], trivia: nil, suppressedTriviaIDs: [], hideSpoilers: true)
        XCTAssertTrue(tabs.isEmpty)
    }

    func testCastOnlyYieldsOnlyCastTab() {
        let cast = [MediaPerson(id: "1", name: "Actor", role: nil, imageURL: nil)]
        let tabs = InsightsTabBarView.availableTabs(cast: cast, trivia: nil, suppressedTriviaIDs: [], hideSpoilers: true)
        XCTAssertEqual(tabs, [.cast])
    }

    func testTopTenTabOmittedWhenNoFactQualifies() {
        let trivia = trivia(facts: [fact(id: "f1", category: .production, interest: 3)])
        let tabs = InsightsTabBarView.availableTabs(cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true)
        XCTAssertFalse(tabs.contains(.topTen))
        XCTAssertTrue(tabs.contains(.category(.production)))
    }

    func testTopTenTabPresentWhenAFactQualifies() {
        let trivia = trivia(facts: [fact(id: "f1", category: .production, interest: 8)])
        let tabs = InsightsTabBarView.availableTabs(cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true)
        XCTAssertTrue(tabs.contains(.topTen))
    }

    func testTabOrderIsTopTenThenCastThenCategoryDeclarationOrder() {
        let cast = [MediaPerson(id: "1", name: "Actor", role: nil, imageURL: nil)]
        let trivia = trivia(facts: [
            fact(id: "f1", category: .music, interest: 8),
            fact(id: "f2", category: .production, interest: 8),
            fact(id: "f3", category: .casting, interest: 3),
        ])
        let tabs = InsightsTabBarView.availableTabs(cast: cast, trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true)
        XCTAssertEqual(tabs, [.topTen, .cast, .category(.production), .category(.casting), .category(.music)])
    }

    func testCategoryWithZeroVisibleFactsAfterFilteringGetsNoTab() {
        // Only fact in .goof is a spoiler; hideSpoilers=true filters it out entirely.
        let trivia = trivia(facts: [fact(id: "f1", category: .goof, spoiler: 1, interest: 8)])
        let tabs = InsightsTabBarView.availableTabs(cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true)
        XCTAssertTrue(tabs.isEmpty, "the only fact is spoiler-filtered out, so no category tab and no Top 10 tab should appear")
    }

    func testSuppressedFactExcludedFromTabAvailability() {
        let trivia = trivia(facts: [fact(id: "f1", category: .lore, interest: 8)])
        let tabs = InsightsTabBarView.availableTabs(cast: [], trivia: trivia, suppressedTriviaIDs: ["f1"], hideSpoilers: true)
        XCTAssertTrue(tabs.isEmpty)
    }

    func testTitleForTab() {
        XCTAssertEqual(InsightsTabBarView.title(for: .topTen), "Top 10")
        XCTAssertEqual(InsightsTabBarView.title(for: .cast), "Cast")
        XCTAssertEqual(InsightsTabBarView.title(for: .category(.production)), "Production")
        XCTAssertEqual(InsightsTabBarView.title(for: .category(.other)), "Trivia")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild test -scheme Rivulet -destination "platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3" -only-testing:RivuletTests/InsightsTabBarViewTests 2>&1 | tail -60
```

Expected: FAIL to compile — `InsightsTabBarView` does not exist yet.

- [ ] **Step 3: Check `MediaPerson`'s exact initializer before writing the view**

The test file above constructs `MediaPerson(id: "1", name: "Actor", role: nil, imageURL: nil)` —
confirm this matches the real initializer signature before proceeding, since a mismatch here is a
compile error in the test file, not the production code:

```bash
grep -n "struct MediaPerson" -A 15 "/Users/bain/git/Swift Projects/Rivulet/Rivulet/Models/"*.swift 2>/dev/null
grep -rn "struct MediaPerson" "/Users/bain/git/Swift Projects/Rivulet/Rivulet/Models/"
```

If the real initializer differs (different parameter names, additional required parameters, or a
different type than `String` for `id`), fix the test file's `MediaPerson(...)` construction calls
to match the real signature — this is a mechanical fix, keep every test's intent identical.

- [ ] **Step 4: Create `InsightsTabBarView.swift`**

Create `Rivulet/Views/Player/UIKit/InsightsTabBarView.swift`:

```swift
//
//  InsightsTabBarView.swift
//  Rivulet
//
//  Pill tab bar for the Insights panel (Docs/superpowers/specs/
//  2026-07-08-insights-toptrivia-tabs-design.md). Replaces the single
//  combined trivia+cast scrolling list with tab-scoped browsing: Top 10,
//  Cast, then one pill per category that has visible facts. Visual/
//  interaction pattern generalized from `SeasonPillView` (capsule shape,
//  selected/focused dual-state styling, focus-previews/select-commits) —
//  that type stays coupled to MediaDetail's season selector; this is a
//  sibling for the player rail panel, not a shared subclass, since the two
//  hosts drive focus differently (season pills are host-gated by
//  `focusEnabled`; this bar is always focusable while in `.list` state).
//

import UIKit

/// One selectable tab in the Insights panel's pill bar.
enum InsightsTab: Hashable {
    case topTen
    case cast
    case category(TriviaCategory)
}

final class InsightsTabBarView: UIView {

    private enum Metrics {
        static let pillSpacing: CGFloat = 8
        static let barHeight: CGFloat = 56
    }

    var onSelect: ((InsightsTab) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var pills: [(tab: InsightsTab, view: InsightsTabPillView)] = []
    private var selected: InsightsTab

    init(tabs: [InsightsTab], selected: InsightsTab) {
        self.selected = selected
        super.init(frame: .zero)
        setUp(tabs: tabs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp(tabs: [InsightsTab]) {
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.clipsToBounds = false
        stack.axis = .horizontal
        stack.spacing = Metrics.pillSpacing

        [scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        scrollView.addSubview(stack)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.barHeight),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        for tab in tabs {
            let pill = InsightsTabPillView()
            pill.configure(title: Self.title(for: tab), isSelected: tab == selected)
            pill.onSelected = { [weak self] in self?.handlePillSelected(tab) }
            stack.addArrangedSubview(pill)
            pills.append((tab, pill))
        }
    }

    private func handlePillSelected(_ tab: InsightsTab) {
        guard tab != selected else { return }
        setSelected(tab)
        onSelect?(tab)
    }

    /// Updates which pill renders as selected without firing `onSelect` —
    /// the host calls this to keep the bar in sync after driving a tab
    /// change itself (e.g. falling back to `.cast` when the active
    /// category's last fact is suppressed at runtime).
    func setSelected(_ tab: InsightsTab) {
        selected = tab
        for (pillTab, pillView) in pills {
            pillView.configure(title: Self.title(for: pillTab), isSelected: pillTab == tab)
        }
    }

    /// Which tabs should be offered given the panel's current cast/trivia
    /// inputs — pure, no UIKit dependency, directly unit-testable. Order:
    /// Top 10 (if >=1 qualifying fact), Cast (if non-empty), then one pill
    /// per `TriviaCategory` (in `TriviaCategory.allCases` declaration order)
    /// that has >=1 visible fact after spoiler/suppression filtering.
    static func availableTabs(
        cast: [MediaPerson],
        trivia: TitleTrivia?,
        suppressedTriviaIDs: Set<String>,
        hideSpoilers: Bool
    ) -> [InsightsTab] {
        var tabs: [InsightsTab] = []
        if let trivia, !trivia.topTenFacts(hideSpoilers: hideSpoilers, suppressed: suppressedTriviaIDs).isEmpty {
            tabs.append(.topTen)
        }
        if !cast.isEmpty {
            tabs.append(.cast)
        }
        if let trivia {
            let visible = trivia.visibleFacts(hideSpoilers: hideSpoilers, suppressed: suppressedTriviaIDs)
            for category in TriviaCategory.allCases where visible.contains(where: { $0.category == category }) {
                tabs.append(.category(category))
            }
        }
        return tabs
    }

    static func title(for tab: InsightsTab) -> String {
        switch tab {
        case .topTen: return "Top 10"
        case .cast: return "Cast"
        case .category(let category): return category.tabDisplayName
        }
    }
}

/// Capsule pill, one per tab. Visual/interaction pattern mirrors
/// `SeasonPillView` (Views/Media/MediaDetail/UIKit/Cells/SeasonPillView.swift):
/// bright frosted capsule when selected OR focused, clear/dim otherwise,
/// 1.05x focus scale, select (not mere focus) commits the change. Kept as
/// its own type rather than reusing `SeasonPillView` directly since that
/// type's `focusEnabled` gating and `MediaDetail`-specific label sizing
/// (31pt) don't fit this bar's always-focusable, more compact context.
private final class InsightsTabPillView: UIControl {

    private let label = UILabel()
    private var isSelectedTab = false
    private var isFocusedPill = false

    var onSelected: (() -> Void)?

    override var canBecomeFocused: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        addTarget(self, action: #selector(handleSelect), for: .primaryActionTriggered)
        layer.cornerCurve = .continuous

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 20, weight: .medium)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    @objc private func handleSelect() { onSelected?() }

    func configure(title: String, isSelected: Bool) {
        label.text = title
        isSelectedTab = isSelected
        applyStyle()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        isFocusedPill = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.applyStyle()
            self.transform = self.isFocusedPill ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
        }, completion: nil)
    }

    private func applyStyle() {
        label.font = .systemFont(ofSize: 20, weight: (isFocusedPill || isSelectedTab) ? .semibold : .medium)
        if isFocusedPill || isSelectedTab {
            backgroundColor = UIColor.white.withAlphaComponent(0.88)
            label.textColor = .black
        } else {
            backgroundColor = .clear
            label.textColor = UIColor.white.withAlphaComponent(0.72)
        }
    }
}
```

- [ ] **Step 5: Add `tabDisplayName` to `TriviaCategory` and remove the now-duplicate private extension**

The private `displayName` extension in `PlayerInsightsPanelView.swift` (bottom of that file)
duplicates what `InsightsTabBarView.title(for:)` needs. Move it to the model file so both call
sites share one source of truth.

In `Rivulet/Models/Insights/TriviaFact.swift`, add this extension at the end of the file (after
the existing `visibleFacts`/`topTenFacts` extension block):

```swift
extension TriviaCategory {
    /// Short display label for the category's row tag and tab pill. Calm, no icons.
    var tabDisplayName: String {
        switch self {
        case .production: return "Production"
        case .casting: return "Casting"
        case .adaptation: return "Adaptation"
        case .reference: return "Reference"
        case .lore: return "Lore"
        case .goof: return "Goof"
        case .music: return "Music"
        case .other: return "Trivia"
        }
    }
}
```

In `Rivulet/Views/Player/UIKit/PlayerInsightsPanelView.swift`, find the private extension at the
bottom of the file:

```swift
private extension TriviaCategory {
    /// Short display label for the row's category tag. Calm, no icons.
    var displayName: String {
        switch self {
        case .production: return "Production"
        case .casting: return "Casting"
        case .adaptation: return "Adaptation"
        case .reference: return "Reference"
        case .lore: return "Lore"
        case .goof: return "Goof"
        case .music: return "Music"
        case .other: return "Trivia"
        }
    }
}
```

Delete this whole block. Then find the one call site that used it —
`Self.displayName` inside `InsightsTriviaRowView`'s `init`:

```swift
        categoryLabel.attributedText = NSAttributedString(
            string: fact.category.displayName.uppercased(),
```

Change `displayName` to `tabDisplayName`:

```swift
        categoryLabel.attributedText = NSAttributedString(
            string: fact.category.tabDisplayName.uppercased(),
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild test -scheme Rivulet -destination "platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3" -only-testing:RivuletTests/InsightsTabBarViewTests 2>&1 | tail -60
```

Expected: all PASS.

- [ ] **Step 7: Full build to confirm the `displayName` → `tabDisplayName` rename didn't break anything else**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild -scheme Rivulet -destination "platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3" -derivedDataPath /tmp/rivulet-dd-c build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && git add Rivulet/Views/Player/UIKit/InsightsTabBarView.swift Rivulet/Models/Insights/TriviaFact.swift Rivulet/Views/Player/UIKit/PlayerInsightsPanelView.swift RivuletTests/Unit/InsightsTabBarViewTests.swift
git commit -m "$(cat <<'EOF'
feat(insights): InsightsTabBarView pill tab bar (Top 10 | Cast | category)

Capsule pill pattern generalized from SeasonPillView. availableTabs() is
pure/unit-tested: Top 10 shown only when a fact qualifies, category pills
only for categories with visible facts after spoiler/suppression
filtering. Moves TriviaCategory's display-name mapping from a private
PlayerInsightsPanelView extension to the model file so both the row label
and the new tab pill share one source of truth.
EOF
)"
```

---

## Task 4: Client — `InsightsCastListView` becomes tab-scoped

**Files:**
- Modify: `Rivulet/Views/Player/UIKit/PlayerInsightsPanelView.swift`
- Test: create `RivuletTests/Unit/InsightsCastListViewTests.swift` (check first whether it exists)

**Interfaces:**
- Consumes: `InsightsTab` (Task 3).
- Produces: `InsightsCastListView` gains
  ```swift
  init(cast: [MediaPerson], trivia: TitleTrivia?, suppressedTriviaIDs: Set<String>,
       hideSpoilers: Bool, initialTab: InsightsTab, onSelectCast: @escaping (MediaPerson) -> Void)
  func setTab(_ tab: InsightsTab)
  ```
  replacing the current `init(cast:trivia:suppressedTriviaIDs:hideSpoilers:onSelect:)` which
  always builds trivia-then-cast into one combined stack. `setTab` clears the stack's arranged
  subviews and `focusableRows`, rebuilds only the given tab's rows, and resets scroll position +
  focus-pinning state so the existing pin-first-focus-then-free landing behavior re-runs for the
  new tab's content.

- [ ] **Step 1: Check for an existing test file and read the current `InsightsCastListView` in full**

```bash
ls "/Users/bain/git/Swift Projects/Rivulet/RivuletTests/Unit/InsightsCastListViewTests.swift" 2>&1
```

If it exists, read it in full before writing new tests — extend it rather than replacing it, and
update any test that constructs `InsightsCastListView` with the old initializer signature (see
Step 4 for the new signature).

- [ ] **Step 2: Write the failing tests**

Create (or add to, if it already exists) `RivuletTests/Unit/InsightsCastListViewTests.swift`:

```swift
//
//  InsightsCastListViewTests.swift
//  RivuletTests
//
//  Tab-scoped row building for the Insights panel's list view.
//

import XCTest
@testable import Rivulet

final class InsightsCastListViewTests: XCTestCase {

    private func fact(id: String, category: TriviaCategory, interest: Int? = nil) -> TriviaFact {
        let json = """
        { "id": "\(id)", "text": "Fact text.", "category": "\(category.rawValue)", "spoiler": 0,
          \(interest.map { "\"interest\": \($0)," } ?? "")
          "source": { "name": "Wikipedia", "url": "https://w/x" } }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TriviaFact.self, from: json)
    }

    private func trivia(facts: [TriviaFact]) -> TitleTrivia {
        let factsJSON = try! JSONEncoder().encode(facts)
        let factsString = String(data: factsJSON, encoding: .utf8)!
        let json = """
        { "id": "tmdb://1", "type": "movie", "generatedAt": "", "pipelineVersion": 2,
          "attribution": [], "facts": \(factsString) }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TitleTrivia.self, from: json)
    }

    func testInitialTabCastShowsOnlyCastRows() {
        let cast = [MediaPerson(id: "1", name: "Actor One", role: nil, imageURL: nil)]
        let trivia = trivia(facts: [fact(id: "f1", category: .production, interest: 8)])
        let view = InsightsCastListView(
            cast: cast, trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .cast, onSelectCast: { _ in })
        XCTAssertEqual(view.triviaRowCount, 0)
        XCTAssertEqual(view.castRowCount, 1)
    }

    func testInitialTabCategoryShowsOnlyThatCategorysFacts() {
        let trivia = trivia(facts: [
            fact(id: "f1", category: .production, interest: 8),
            fact(id: "f2", category: .casting, interest: 8),
        ])
        let view = InsightsCastListView(
            cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .category(.production), onSelectCast: { _ in })
        XCTAssertEqual(view.triviaRowCount, 1)
        XCTAssertEqual(view.castRowCount, 0)
    }

    func testInitialTabTopTenShowsOnlyQualifyingFacts() {
        let trivia = trivia(facts: [
            fact(id: "f1", category: .production, interest: 9),
            fact(id: "f2", category: .casting, interest: 3),
        ])
        let view = InsightsCastListView(
            cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .topTen, onSelectCast: { _ in })
        XCTAssertEqual(view.triviaRowCount, 1)
    }

    func testSetTabRebuildsRowsForNewTab() {
        let cast = [MediaPerson(id: "1", name: "Actor One", role: nil, imageURL: nil)]
        let trivia = trivia(facts: [fact(id: "f1", category: .production, interest: 8)])
        let view = InsightsCastListView(
            cast: cast, trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .cast, onSelectCast: { _ in })
        XCTAssertEqual(view.castRowCount, 1)
        XCTAssertEqual(view.triviaRowCount, 0)

        view.setTab(.category(.production))
        XCTAssertEqual(view.castRowCount, 0)
        XCTAssertEqual(view.triviaRowCount, 1)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild test -scheme Rivulet -destination "platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3" -only-testing:RivuletTests/InsightsCastListViewTests 2>&1 | tail -60
```

Expected: FAIL to compile — no `initialTab`/`onSelectCast` initializer, no `setTab`, no
`castRowCount`.

- [ ] **Step 4: Rewrite `InsightsCastListView` to be tab-scoped**

In `Rivulet/Views/Player/UIKit/PlayerInsightsPanelView.swift`, replace the entire
`InsightsCastListView` class (from `final class InsightsCastListView: UIView {` through its
closing `}` — everything before the `// MARK: - InsightsCastRowButton` comment) with:

```swift
final class InsightsCastListView: UIView {

    private enum Metrics {
        static let maxHeight: CGFloat = 620
        // Horizontal inset for the row stack inside the scroll view so the
        // focused row's 1.02 scale doesn't overflow the clipping scroll
        // view's left/right edges. Matches UpNextListView.
        static let rowInset: CGFloat = 8
    }

    /// The panel's overall width is a fixed constant (`PlayerRailPanelView`
    /// presents Insights at width 640 — see `PlayerContainerViewController`),
    /// so the trivia row's final text width is knowable up front rather than
    /// discovered from a layout pass: 640 - 2*20 (PlayerRailPanelView content
    /// padding) - 2*rowInset (this stack's own inset) - 2*18 (row's own
    /// internal padding, `InsightsTriviaRowView`). Computing the row's
    /// intrinsic height from this fixed width up front (instead of waiting
    /// for `layoutSubviews`) avoids the width-before-height circular
    /// dependency that left every trivia row pinned to UIStackView's ~44pt
    /// ambiguous-layout fallback regardless of actual text length.
    static let triviaRowContentWidth: CGFloat = 640 - 2 * 20 - 2 * Metrics.rowInset - 2 * 18

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var castRows: [InsightsCastRowButton] = []
    /// Every focusable row in the CURRENTLY DISPLAYED tab's content, in
    /// display order. Rebuilt on every `setTab`/`init`. Trivia rows are
    /// focusable purely so the tvOS focus engine can scroll to them; without
    /// them here the panel can't scroll past a single-tab's trivia list.
    private var focusableRows: [UIView] = []
    /// Pin focus to the first row only on the FIRST landing of the CURRENT
    /// tab; reset to false on every `setTab` so switching tabs re-lands
    /// focus on that tab's first row rather than leaving it stranded on a
    /// now-hidden row from the previous tab.
    private var hasPinnedInitialFocus = false

    private let cast: [MediaPerson]
    private let trivia: TitleTrivia?
    private let suppressedTriviaIDs: Set<String>
    private let hideSpoilers: Bool
    private let onSelectCast: (MediaPerson) -> Void

    /// Number of trivia fact rows currently in the stack (i.e. for the
    /// currently displayed tab). Internal (not private) so `@testable import
    /// Rivulet` tests can assert tab-scoped row counts without reaching into
    /// UIKit's `UIStackView.arrangedSubviews` directly.
    var triviaRowCount: Int {
        stack.arrangedSubviews.filter { $0 is InsightsTriviaRowView }.count
    }
    /// Whether the current tab's trivia section has any rows. Kept for the
    /// pre-existing `InsightsTriviaPanelTests` graceful-absent assertions
    /// (Task 4 Step 9 rewrites that file for the new tab-scoped API, but
    /// keeps this exact property name/meaning).
    var hasTriviaSection: Bool { triviaRowCount > 0 }
    /// Number of cast rows currently in the stack. Internal for the same
    /// testing reason as `triviaRowCount`.
    var castRowCount: Int {
        stack.arrangedSubviews.filter { $0 is InsightsCastRowButton }.count
    }

    init(
        cast: [MediaPerson],
        trivia: TitleTrivia?,
        suppressedTriviaIDs: Set<String>,
        hideSpoilers: Bool,
        initialTab: InsightsTab,
        onSelectCast: @escaping (MediaPerson) -> Void
    ) {
        self.cast = cast
        self.trivia = trivia
        self.suppressedTriviaIDs = suppressedTriviaIDs
        self.hideSpoilers = hideSpoilers
        self.onSelectCast = onSelectCast
        super.init(frame: .zero)
        setupContent()
        buildRows(for: initialTab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        stack.axis = .vertical
        stack.spacing = 8
        scrollView.addSubview(stack)
        scrollView.clipsToBounds = true

        [scrollView, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(scrollView)

        // Scroll view caps content up to a maxHeight, so a short tab's
        // content hugs its rows while a long one scrolls.
        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        scrollHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxHeight),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Metrics.rowInset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Metrics.rowInset),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -(Metrics.rowInset * 2)),
        ])
    }

    /// Tears down the current tab's rows and builds the given tab's rows in
    /// their place. Resets scroll position and focus-pinning so the existing
    /// pin-first-focus-then-free landing behavior re-runs for the new
    /// content (mirrors how a fresh `UpNextListView` lands focus on reload).
    func setTab(_ tab: InsightsTab) {
        castRows.forEach { $0.cancelImageLoad() }
        castRows.removeAll()
        focusableRows.removeAll()
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        hasPinnedInitialFocus = false
        scrollView.setContentOffset(.zero, animated: false)
        buildRows(for: tab)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func buildRows(for tab: InsightsTab) {
        switch tab {
        case .topTen:
            let facts = trivia?.topTenFacts(hideSpoilers: hideSpoilers, suppressed: suppressedTriviaIDs) ?? []
            buildTriviaRows(facts)
        case .cast:
            buildCastRows(cast)
        case .category(let category):
            let facts = (trivia?.visibleFacts(hideSpoilers: hideSpoilers, suppressed: suppressedTriviaIDs) ?? [])
                .filter { $0.category == category }
            buildTriviaRows(facts)
        }
        if !trivia.map({ $0.attribution }).map(\.isEmpty).map({ !$0 }).contains(false), tab != .cast {
            addAttributionFooterIfNeeded()
        }
    }

    private func buildTriviaRows(_ facts: [TriviaFact]) {
        for fact in facts {
            let row = InsightsTriviaRowView(fact: fact, contentWidth: Self.triviaRowContentWidth)
            stack.addArrangedSubview(row)
            focusableRows.append(row)
        }
    }

    private func buildCastRows(_ cast: [MediaPerson]) {
        for person in cast {
            let row = InsightsCastRowButton(person: person)
            row.onTap = { [onSelectCast] in onSelectCast(person) }
            stack.addArrangedSubview(row)
            castRows.append(row)
            focusableRows.append(row)
        }
    }

    private func addAttributionFooterIfNeeded() {
        guard let trivia, !trivia.attribution.isEmpty, let last = stack.arrangedSubviews.last else { return }
        let footer = UILabel()
        footer.numberOfLines = 1
        footer.font = .systemFont(ofSize: 15, weight: .regular)
        footer.textColor = UIColor.white.withAlphaComponent(0.35)
        let names = trivia.attribution.map(\.name).joined(separator: " · ")
        footer.text = "Info from \(names)"
        stack.setCustomSpacing(12, after: last)
        stack.addArrangedSubview(footer)
    }

    // MARK: - Teardown

    override func removeFromSuperview() {
        castRows.forEach { $0.cancelImageLoad() }
        super.removeFromSuperview()
    }

    deinit {
        castRows.forEach { $0.cancelImageLoad() }
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Once focus has landed, express no preference so the engine keeps
        // focus on the current row (no bounce back to the first row).
        guard !hasPinnedInitialFocus else { return [] }
        if let first = focusableRows.first { return [first] }
        return [self]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // Once focus enters any of our rows, stop pinning the first row.
        if let next = context.nextFocusedView, focusableRows.contains(where: { next.isDescendant(of: $0) || next === $0 }) {
            hasPinnedInitialFocus = true
        }
    }
}
```

**Note on the `addAttributionFooterIfNeeded` guard condition above:** the line
`if !trivia.map({ $0.attribution }).map(\.isEmpty).map({ !$0 }).contains(false), tab != .cast {`
is deliberately convoluted busywork — replace `buildRows(for:)`'s footer-guard with the simpler,
equivalent form below instead of the one shown. Use this corrected version of `buildRows(for:)`:

```swift
    private func buildRows(for tab: InsightsTab) {
        switch tab {
        case .topTen:
            let facts = trivia?.topTenFacts(hideSpoilers: hideSpoilers, suppressed: suppressedTriviaIDs) ?? []
            buildTriviaRows(facts)
            addAttributionFooterIfNeeded()
        case .cast:
            buildCastRows(cast)
        case .category(let category):
            let facts = (trivia?.visibleFacts(hideSpoilers: hideSpoilers, suppressed: suppressedTriviaIDs) ?? [])
                .filter { $0.category == category }
            buildTriviaRows(facts)
            addAttributionFooterIfNeeded()
        }
    }
```

(`addAttributionFooterIfNeeded` already no-ops correctly if `stack.arrangedSubviews` is empty —
its own `guard ... let last = stack.arrangedSubviews.last else { return }` — so calling it
unconditionally for the two trivia-bearing tab cases is correct and simpler than threading an
extra condition through `buildRows`.)

- [ ] **Step 5: Update `InsightsPanelContainerView` to construct `InsightsCastListView` with the new signature and own tab state**

`InsightsCastListView`'s old `init(cast:trivia:suppressedTriviaIDs:hideSpoilers:onSelect:)` no
longer exists — `InsightsPanelContainerView`'s `listView` construction must be updated, and the
container needs to own an `InsightsTabBarView` above `listView`.

In `Rivulet/Views/Player/UIKit/InsightsPanelContainerView.swift`, replace the whole file with:

```swift
//
//  InsightsPanelContainerView.swift
//  Rivulet
//
//  Two-state content for the Insights rail panel (Docs/superpowers/specs/
//  2026-07-08-insights-toptrivia-tabs-design.md). Replaces the old
//  person-page deep link: selecting a cast member CROSSFADES IN PLACE from
//  the cast list to an actor view (portrait + bio + filmography) while video
//  keeps playing — no pause/resume, no VC presentation anywhere in this flow.
//  Above the list/actor content sits a pill tab bar (Top 10 | Cast |
//  category pills) that switches which tab-scoped row set the list shows.
//
//  Menu handling (mirrors the panel's own Menu ownership rather than
//  fighting it): in `.actor` state Menu is CONSUMED here (reverse-crossfade
//  back to `.list`); in `.list` state Menu is NOT consumed, so it bubbles to
//  `PlayerRailPanelView.pressesBegan`, which dismisses the whole panel.
//

import UIKit

final class InsightsPanelContainerView: UIView {

    private enum Metrics {
        /// Height cap for the `.actor` state — matches PlayerRailPanelView's
        /// own `maxHeight` (560) minus its content padding (20 top + 20
        /// bottom), so the panel never exceeds its own ceiling.
        static let actorHeightCap: CGFloat = 520
        static let crossfadeDuration: TimeInterval = 0.2
        static let tabBarSpacing: CGFloat = 16
    }

    private enum State {
        case list
        case actor
    }

    private let cast: [MediaPerson]
    private let trivia: TitleTrivia?
    private let suppressedTriviaIDs: Set<String>
    private let hideSpoilers: Bool
    private let provider: PersonFilmographyProviding

    private let availableTabs: [InsightsTab]
    private var currentTab: InsightsTab

    private lazy var tabBar: InsightsTabBarView? = {
        guard !availableTabs.isEmpty else { return nil }
        let bar = InsightsTabBarView(tabs: availableTabs, selected: currentTab)
        bar.onSelect = { [weak self] tab in self?.handleTabSelected(tab) }
        return bar
    }()

    // `lazy` so the init closure can capture `self` directly — evaluated on
    // first access (from `init`, after `super.init()` has returned), so
    // `self` is fully formed by the time `InsightsCastListView`'s own init
    // runs. Simpler than routing through an intermediate box.
    private lazy var listView = InsightsCastListView(
        cast: cast,
        trivia: trivia,
        suppressedTriviaIDs: suppressedTriviaIDs,
        hideSpoilers: hideSpoilers,
        initialTab: currentTab,
        onSelectCast: { [weak self] person in
            self?.crossfadeToActor(person)
        })
    /// Internal (not private) visibility so `@testable import Rivulet` tests
    /// can observe the currently-hosted actor view (e.g. to confirm a stale
    /// load never reached it after the user backed out / switched actors).
    private(set) var actorView: InsightsActorView?
    private let coordinator = InsightsActorLoadCoordinator()
    private var state: State = .list

    private var heightConstraint: NSLayoutConstraint!

    init(
        cast: [MediaPerson],
        trivia: TitleTrivia? = nil,
        suppressedTriviaIDs: Set<String> = [],
        hideSpoilers: Bool = true,
        provider: PersonFilmographyProviding = PersonFilmographyProvider()
    ) {
        self.cast = cast
        self.trivia = trivia
        self.suppressedTriviaIDs = suppressedTriviaIDs
        self.hideSpoilers = hideSpoilers
        self.provider = provider
        let tabs = InsightsTabBarView.availableTabs(
            cast: cast, trivia: trivia, suppressedTriviaIDs: suppressedTriviaIDs, hideSpoilers: hideSpoilers)
        self.availableTabs = tabs
        // Prefer Top 10 as the landing tab when available (it's the curated
        // highlight reel); otherwise Cast; otherwise the first category.
        self.currentTab = tabs.first(where: { $0 == .topTen }) ?? tabs.first ?? .cast
        super.init(frame: .zero)

        listView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listView)

        if let tabBar {
            tabBar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tabBar)
            NSLayoutConstraint.activate([
                tabBar.topAnchor.constraint(equalTo: topAnchor),
                tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
                tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),

                listView.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: Metrics.tabBarSpacing),
                listView.leadingAnchor.constraint(equalTo: leadingAnchor),
                listView.trailingAnchor.constraint(equalTo: trailingAnchor),
                listView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                listView.topAnchor.constraint(equalTo: topAnchor),
                listView.leadingAnchor.constraint(equalTo: leadingAnchor),
                listView.trailingAnchor.constraint(equalTo: trailingAnchor),
                listView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Tab switching

    private func handleTabSelected(_ tab: InsightsTab) {
        guard tab != currentTab, state == .list else { return }
        currentTab = tab
        listView.setTab(tab)
    }

    // MARK: - Crossfade

    /// Internal (not private) visibility so `@testable import Rivulet`
    /// integration tests can drive selection directly (in production this
    /// only ever fires from `InsightsCastListView`'s row `onSelect`).
    func crossfadeToActor(_ person: MediaPerson) {
        guard state == .list else { return }
        let token = coordinator.begin()

        let actor = InsightsActorView(person: person)
        actor.translatesAutoresizingMaskIntoConstraints = false
        actor.alpha = 0
        addSubview(actor)
        NSLayoutConstraint.activate([
            actor.topAnchor.constraint(equalTo: topAnchor),
            actor.leadingAnchor.constraint(equalTo: leadingAnchor),
            actor.trailingAnchor.constraint(equalTo: trailingAnchor),
            actor.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        actorView = actor
        state = .actor

        heightConstraint.constant = Metrics.actorHeightCap
        heightConstraint.isActive = true
        setNeedsFocusUpdate()
        updateFocusIfNeeded()

        UIView.animate(withDuration: Metrics.crossfadeDuration, animations: {
            self.listView.alpha = 0
            self.tabBar?.alpha = 0
            actor.alpha = 1
            self.superview?.layoutIfNeeded()
        }, completion: { [weak self] _ in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        })

        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.provider.load(person: person)
            guard self.coordinator.isCurrent(token) else { return }
            // The actor view for THIS token is still `self.actorView` as
            // long as no newer selection/cancel has happened (guaranteed by
            // the token check above — cancel()/begin() are the only ways
            // the token goes stale, and both accompany a state change that
            // replaces or tears down `actorView`).
            if let result {
                actor.populate(result)
            } else {
                actor.showDetailsUnavailable()
            }
        }
    }

    /// Internal (not private) visibility — see `crossfadeToActor`.
    func reverseCrossfadeToList() {
        guard state == .actor, let actor = actorView else { return }
        coordinator.cancel()
        state = .list

        heightConstraint.isActive = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()

        UIView.animate(withDuration: Metrics.crossfadeDuration, animations: {
            actor.alpha = 0
            self.listView.alpha = 1
            self.tabBar?.alpha = 1
            self.superview?.layoutIfNeeded()
        }, completion: { [weak self] _ in
            actor.removeFromSuperview()
            if self?.actorView === actor {
                self?.actorView = nil
            }
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        })
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        switch state {
        case .list: return [listView]
        case .actor: return actorView.map { [$0] } ?? [listView]
        }
    }

    // MARK: - Menu handling

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            if state == .actor {
                reverseCrossfadeToList()
                return  // consumed — stays open, back to the cast list
            }
            // .list state: fall through to super so this bubbles to
            // PlayerRailPanelView, which owns closing the whole panel.
            break
        }
        super.pressesBegan(presses, with: event)
    }
}
```

Note: the tab bar itself is not wired into the `preferredFocusEnvironments`/focus chain
explicitly — it relies on the tvOS focus engine's spatial navigation (Up from the list's first row
reaches the tab bar naturally, since it's the sibling immediately above `listView` in the view
hierarchy) plus its own `InsightsTabPillView.canBecomeFocused == true`. This matches the existing
codebase's general approach of letting spatial navigation handle sibling relationships rather than
hand-wiring every adjacency (see the `rivulet-tvos-uikit` skill's guidance on
`preferredFocusEnvironments` being for *default landing preference*, not a full focus graph).

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild test -scheme Rivulet -destination "platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3" -only-testing:RivuletTests/InsightsCastListViewTests -only-testing:RivuletTests/InsightsTabBarViewTests -only-testing:RivuletTests/TriviaFactTests 2>&1 | tail -80
```

Expected: all PASS.

- [ ] **Step 7: Rewrite `RivuletTests/Unit/InsightsTriviaPanelTests.swift` for the new tab-scoped API**

This pre-existing test file constructs `InsightsCastListView` with the OLD signature
(`cast:trivia:onSelect:` and `cast:trivia:suppressedTriviaIDs:hideSpoilers:onSelect:`, no
`initialTab`/`onSelectCast`) six times, and one test walks `InsightsPanelContainerView`'s subviews
to find the list view. Replace the whole file with this version, which keeps every existing test's
intent (graceful-absent rules, suppression, hide-spoilers) but drives them through an explicit
`initialTab: .category(.production)` so each test is unambiguous about which tab it's checking,
independent of the container's own tab-selection defaulting logic (covered separately by Task 3's
`InsightsTabBarViewTests` and Task 4's `InsightsCastListViewTests`):

```swift
//
//  InsightsTriviaPanelTests.swift
//  RivuletTests
//
//  Panel-level coverage for the Trivia rows rendered by a single tab of
//  `InsightsCastListView` (Docs/superpowers/specs/
//  2026-07-08-insights-toptrivia-tabs-design.md). `TriviaFactTests` already
//  covers `visibleFacts`/`topTenFacts` filtering in isolation; this proves
//  a tab's filtered result wires into the view correctly — including the
//  graceful-absent rule (no trivia / everything filtered out for this tab
//  -> zero rows, same as cast's empty state). Each test drives an explicit
//  `initialTab` so it is independent of `InsightsPanelContainerView`'s own
//  tab-selection defaulting (covered by `InsightsCastListViewTests`).
//

import XCTest
@testable import Rivulet

@MainActor
final class InsightsTriviaPanelTests: XCTestCase {

    private func makeFact(_ id: String, spoiler: Int = 0, category: TriviaCategory = .production) -> TriviaFact {
        let json = """
        { "id": "\(id)", "text": "Fact \(id).", "category": "\(category.rawValue)", "spoiler": \(spoiler),
          "source": { "name": "Wikipedia", "url": "https://w/x" } }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TriviaFact.self, from: json)
    }

    private func makeTrivia(facts: [TriviaFact], attribution: [TriviaSource] = [TriviaSource(name: "Wikipedia", url: "https://w/x")]) -> TitleTrivia {
        let factsJSON = facts.map {
            """
            { "id": "\($0.id)", "text": "\($0.text)", "category": "\($0.category.rawValue)", "spoiler": \($0.spoiler),
              "source": { "name": "\($0.source.name)", "url": "\($0.source.url)" } }
            """
        }.joined(separator: ",")
        let attributionJSON = attribution.map { "{ \"name\": \"\($0.name)\", \"url\": \"\($0.url)\" }" }.joined(separator: ",")
        let json = """
        { "id": "tmdb://1", "type": "movie", "generatedAt": "2026-07-07T00:00:00Z", "pipelineVersion": 2,
          "attribution": [\(attributionJSON)], "facts": [\(factsJSON)] }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TitleTrivia.self, from: json)
    }

    func test_noTrivia_sectionAbsent() {
        let list = InsightsCastListView(
            cast: [], trivia: nil, suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .category(.production), onSelectCast: { _ in })
        XCTAssertEqual(list.triviaRowCount, 0)
        XCTAssertFalse(list.hasTriviaSection)
    }

    func test_triviaWithNoFacts_sectionAbsent() {
        let trivia = makeTrivia(facts: [])
        let list = InsightsCastListView(
            cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .category(.production), onSelectCast: { _ in })
        XCTAssertEqual(list.triviaRowCount, 0)
        XCTAssertFalse(list.hasTriviaSection)
    }

    func test_allFactsFilteredBySpoilers_sectionAbsent() {
        // Every fact is spoiler-tagged; hiding spoilers should leave nothing,
        // so the whole section (not just the rows) must vanish gracefully.
        let trivia = makeTrivia(facts: [makeFact("f1", spoiler: 1), makeFact("f2", spoiler: 2)])
        let list = InsightsCastListView(
            cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .category(.production), onSelectCast: { _ in })
        XCTAssertEqual(list.triviaRowCount, 0)
        XCTAssertFalse(list.hasTriviaSection)
    }

    func test_visibleFacts_renderAsRows() {
        let trivia = makeTrivia(facts: [makeFact("f1", spoiler: 0), makeFact("f2", spoiler: 0)])
        let list = InsightsCastListView(
            cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .category(.production), onSelectCast: { _ in })
        XCTAssertEqual(list.triviaRowCount, 2)
        XCTAssertTrue(list.hasTriviaSection)
    }

    func test_suppressedFactIsExcludedFromRows() {
        let trivia = makeTrivia(facts: [makeFact("f1", spoiler: 0), makeFact("f2", spoiler: 0)])
        let list = InsightsCastListView(
            cast: [], trivia: trivia, suppressedTriviaIDs: ["f2"], hideSpoilers: false,
            initialTab: .category(.production), onSelectCast: { _ in })
        XCTAssertEqual(list.triviaRowCount, 1, "the suppressed fact must not render as a row")
    }

    func test_hideSpoilersOff_showsSpoilerFacts() {
        let trivia = makeTrivia(facts: [makeFact("f1", spoiler: 1)])
        let list = InsightsCastListView(
            cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: false,
            initialTab: .category(.production), onSelectCast: { _ in })
        XCTAssertEqual(list.triviaRowCount, 1, "with hide-spoilers off, a spoiler-tagged fact must still render")
    }

    /// The container forwards its trivia args through to the list view
    /// unchanged — a thin plumbing check that the two-state container
    /// doesn't drop or mistranslate them. A single production-category fact
    /// with no interest score means the container's default-tab logic lands
    /// on `.category(.production)` (no Top 10 pill, since nothing scored
    /// >=7; Cast is also absent since cast is empty) — so this exercises the
    /// container's real default-tab wiring end to end, not a hand-picked tab.
    func test_containerForwardsTriviaToListView() {
        let trivia = makeTrivia(facts: [makeFact("f1", spoiler: 0)])
        let container = InsightsPanelContainerView(cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: false)
        // The container's `preferredFocusEnvironments` in `.list` state
        // returns the hosted list view; walk its subviews to find it and
        // confirm a trivia row made it through.
        let listView = container.subviews.compactMap { $0 as? InsightsCastListView }.first
        XCTAssertEqual(listView?.triviaRowCount, 1)
    }
}
```

- [ ] **Step 8: Check for any other callers of the old `InsightsCastListView`/`InsightsPanelContainerView` initializers**

```bash
grep -rn "InsightsCastListView(" "/Users/bain/git/Swift Projects/Rivulet/Rivulet" "/Users/bain/git/Swift Projects/Rivulet/RivuletTests" --include="*.swift"
grep -rn "InsightsPanelContainerView(" "/Users/bain/git/Swift Projects/Rivulet/Rivulet" "/Users/bain/git/Swift Projects/Rivulet/RivuletTests" --include="*.swift"
```

`InsightsPanelContainerView`'s public initializer signature is unchanged (still
`cast:trivia:suppressedTriviaIDs:hideSpoilers:provider:`), so its one call site in
`PlayerContainerViewController.swift` (`rail.onInsights`) needs no change. Step 7 above already
handles the six call sites in `InsightsTriviaPanelTests.swift`. Confirm no other file constructs
`InsightsCastListView(...)` directly — grep should now show only
`InsightsPanelContainerView.swift`'s `listView` property and the test files created/rewritten in
this plan (Task 4 Steps 2 and 7).

- [ ] **Step 9: Full build**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild -scheme Rivulet -destination "platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3" -derivedDataPath /tmp/rivulet-dd-c build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Full test suite**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild test -scheme Rivulet -destination "platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3" 2>&1 | tail -100
```

Expected: all PASS, including the rewritten `InsightsTriviaPanelTests.swift` (Step 7) and the new
`InsightsCastListViewTests.swift` (Step 2).

- [ ] **Step 11: Commit**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && git add Rivulet/Views/Player/UIKit/PlayerInsightsPanelView.swift Rivulet/Views/Player/UIKit/InsightsPanelContainerView.swift RivuletTests/Unit/InsightsCastListViewTests.swift RivuletTests/Unit/InsightsTriviaPanelTests.swift
git commit -m "$(cat <<'EOF'
feat(insights): tab-scoped InsightsCastListView + wire InsightsTabBarView

InsightsCastListView now renders only the active tab's rows (rebuilt via
setTab) instead of always combining trivia-then-cast in one stack.
InsightsPanelContainerView owns tab-bar placement above the list, defaults
to Top 10 when available else Cast else the first category, and hides the
tab bar during the actor crossfade (existing crossfade behavior otherwise
unchanged).
EOF
)"
```

---

## Task 5: Manual verification on simulator

**Files:** none (verification only).

**Interfaces:** none — this task exercises the full stack built in Tasks 1-4.

- [ ] **Step 1: Build and install to the simulator**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild -scheme Rivulet -configuration Release -destination "platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3" -derivedDataPath /tmp/rivulet-dd-c build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
xcrun simctl install 33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3 "/tmp/rivulet-dd-c/Build/Products/Release-appletvsimulator/Rivulet.app"
xcrun simctl launch 33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3 com.gstudios.rivulet
```

- [ ] **Step 2: Verify a title with real interest scores**

Requires the pipeline (Task 1) to have actually re-generated at least one title with
`PIPELINE_VERSION = 2` and real `interest` scores — coordinate with whoever runs the Unraid
pipeline worker, or manually trigger regeneration for one title (e.g. Ratatouille) via its
existing on-play trigger, then wait for the pipeline to publish. Confirm via the Insights rail
button on that title:
- The pill bar shows `Top 10` first (if any fact scored ≥7), then `Cast`, then category pills in
  `TriviaCategory.allCases` order — only for categories with visible facts.
- Selecting `Top 10` shows facts sorted highest-interest-first, capped at 10.
- Selecting a category pill shows only that category's facts.
- Selecting `Cast` shows only cast rows; selecting a cast row still crossfades to the actor view
  exactly as before.
- Pressing Menu from the actor view reverse-crossfades back to the list, landing on whichever tab
  was active before the cast row was selected (not reset to Top 10/Cast).
- Focus-driven scroll works within each tab's list the same way it did before this change (no
  regression of the `intrinsicContentSize`-based trivia row sizing from the prior session's fix).

- [ ] **Step 3: Verify a title NOT yet regenerated (old schema, no interest scores)**

Open the Insights panel on a title whose trivia was published before this pipeline change. Confirm:
- No `Top 10` pill appears.
- `Cast` and category pills work normally.
- No crash, no blank panel.

- [ ] **Step 4: Report findings**

Report back what was visually confirmed (or any discrepancy found) rather than assuming success —
this step cannot be verified by an automated test, only by direct observation on the simulator.
