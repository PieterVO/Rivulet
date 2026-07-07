"""Tests for the discover stage's pure ranking/decision/parsing logic.

Network calls (Wikipedia opensearch, Fandom search) and the LLM adjudication
call are never made here; `resolve_one` is exercised via a fake ChatClient
and monkeypatched fetch functions where an end-to-end check is useful, but
the bulk of coverage is on the pure functions per the plan's "ambiguous/no-
match -> logged and skipped, not guessed" requirement.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from insights.stages.discover import (
    SourceCandidate,
    SourceMapEntry,
    adjudication_prompt,
    decide_source,
    load_sourcemap_jsonl,
    parse_adjudication_answer,
    parse_fandom_search,
    parse_wikipedia_opensearch,
    parse_wikipedia_query_extracts,
    rank_candidates,
    rank_fandom_landing_first,
    status_for,
    write_sourcemap_jsonl,
)
from insights.stages.seed import WorkItem


def test_rank_candidates_exact_title_and_year_wins() -> None:
    work_item = WorkItem(tmdb_id=1, type="movie", title="Silo", year=2023)
    candidates = [
        SourceCandidate(title="Silo (comics)", url="https://w/comics"),
        SourceCandidate(title="Silo (TV series)", url="https://w/tv", snippet="a 2023 series"),
        SourceCandidate(title="Silo", url="https://w/plain"),
    ]
    ranked = rank_candidates(candidates, work_item)
    # "Silo (TV series)" scores type-hint(+1); "Silo" scores exact-match(+3).
    # Neither has year 2023 IN THE TITLE, so exact match wins on score.
    assert ranked[0].url == "https://w/plain"


def test_rank_candidates_demotes_disambiguation_pages() -> None:
    work_item = WorkItem(tmdb_id=1, type="movie", title="Inception", year=2010)
    candidates = [
        SourceCandidate(title="Inception (disambiguation)", url="https://w/disambig"),
        SourceCandidate(title="Inception (2010 film)", url="https://w/2010film"),
    ]
    ranked = rank_candidates(candidates, work_item)
    assert ranked[0].url == "https://w/2010film"
    assert ranked[-1].url == "https://w/disambig"


def test_rank_candidates_year_in_parens_scores_higher() -> None:
    work_item = WorkItem(tmdb_id=1, type="tv", title="The Office", year=2005)
    candidates = [
        SourceCandidate(title="The Office (UK TV series)", url="https://w/uk"),
        SourceCandidate(title="The Office (2005 TV series)", url="https://w/us"),
    ]
    ranked = rank_candidates(candidates, work_item)
    assert ranked[0].url == "https://w/us"


def test_rank_candidates_stable_order_on_tie() -> None:
    work_item = WorkItem(tmdb_id=1, type="movie", title="Unrelated Query", year=None)
    candidates = [
        SourceCandidate(title="Foo", url="https://w/a"),
        SourceCandidate(title="Bar", url="https://w/b"),
    ]
    ranked = rank_candidates(candidates, work_item)
    assert [c.url for c in ranked] == ["https://w/a", "https://w/b"]


def test_decide_source_requires_confirmation() -> None:
    wiki = [SourceCandidate(title="X", url="https://w/x")]
    fandom = [SourceCandidate(title="Y", url="https://f/y")]

    # Neither confirmed -> neither committed.
    assert decide_source(wiki, fandom, False, False) == (None, None)
    # Only wikipedia confirmed.
    assert decide_source(wiki, fandom, True, False) == ("https://w/x", None)
    # Both confirmed.
    assert decide_source(wiki, fandom, True, True) == ("https://w/x", "https://f/y")


def test_decide_source_no_candidates_means_nothing_to_confirm() -> None:
    assert decide_source([], [], True, True) == (None, None)


def test_status_for_resolved_ambiguous_no_match() -> None:
    assert status_for("https://w/x", None, had_candidates=True) == "resolved"
    assert status_for(None, None, had_candidates=True) == "ambiguous"
    assert status_for(None, None, had_candidates=False) == "no_match"


def test_parse_adjudication_answer_variants() -> None:
    assert parse_adjudication_answer("yes") is True
    assert parse_adjudication_answer("Yes.") is True
    assert parse_adjudication_answer("  YES!  ") is True
    assert parse_adjudication_answer("no") is False
    assert parse_adjudication_answer("No, this is about something else.") is False
    assert parse_adjudication_answer("unsure") is False


def test_adjudication_prompt_includes_year_and_episode() -> None:
    work_item = WorkItem(tmdb_id=1, type="tv", title="Silo", year=2023, season=1, episode=3)
    candidate = SourceCandidate(title="Silo (TV series)", url="https://w/x", snippet="snip")
    prompt = adjudication_prompt(work_item, candidate)
    assert "Silo" in prompt
    assert "2023" in prompt
    assert "season 1 episode 3" in prompt
    assert "snip" in prompt


def test_parse_wikipedia_opensearch() -> None:
    payload = [
        "Inception",
        ["Inception (2010 film)", "Inception (disambiguation)"],
        ["A 2010 film.", "Inception may refer to:"],
        ["https://en.wikipedia.org/wiki/Inception_(2010_film)", "https://en.wikipedia.org/wiki/Inception_(disambiguation)"],
    ]
    candidates = parse_wikipedia_opensearch(payload)
    assert len(candidates) == 2
    assert candidates[0].title == "Inception (2010 film)"
    assert candidates[0].url.endswith("Inception_(2010_film)")


def test_parse_wikipedia_opensearch_malformed_returns_empty() -> None:
    assert parse_wikipedia_opensearch([]) == []
    assert parse_wikipedia_opensearch(["q"]) == []


def test_parse_fandom_search_builds_page_url_and_strips_html() -> None:
    payload = {
        "query": {
            "search": [
                {"title": "Silo (TV series)", "snippet": "A <b>2023</b> series"},
            ]
        }
    }
    candidates = parse_fandom_search(payload, "silo")
    assert candidates[0].url == "https://silo.fandom.com/wiki/Silo_(TV_series)"
    assert candidates[0].snippet == "A 2023 series"


def test_parse_fandom_search_no_results() -> None:
    assert parse_fandom_search({"query": {"search": []}}, "silo") == []


def test_sourcemap_entry_round_trip() -> None:
    entry = SourceMapEntry(
        key="movie:27205",
        wikipedia_url="https://w/x",
        fandom_wiki=None,
        fandom_page_url=None,
        status="resolved",
    )
    again = SourceMapEntry.from_dict(json.loads(json.dumps(entry.to_dict())))
    assert again == entry


def test_write_and_load_sourcemap_jsonl_keyed_by_work_item_key(tmp_path: Path) -> None:
    entries = [
        SourceMapEntry("movie:1", "https://w/1", None, None, "resolved"),
        SourceMapEntry("tv:2:S1E1", None, "fandomwiki", "https://f/2", "resolved"),
        SourceMapEntry("movie:3", None, None, None, "no_match"),
    ]
    path = tmp_path / "sourcemap.jsonl"
    write_sourcemap_jsonl(entries, path)

    loaded = load_sourcemap_jsonl(path)
    assert set(loaded.keys()) == {"movie:1", "tv:2:S1E1", "movie:3"}
    assert loaded["movie:1"].wikipedia_url == "https://w/1"


def test_load_sourcemap_jsonl_missing_file_returns_empty(tmp_path: Path) -> None:
    assert load_sourcemap_jsonl(tmp_path / "nope.jsonl") == {}


class _FakeChatClient:
    """Fake ChatClient returning scripted `chat()` replies in call order."""

    def __init__(self, replies: list[str]) -> None:
        self._replies = list(replies)
        self.prompts: list[str] = []

    def chat(self, system_prompt: str, user_prompt: str) -> str:
        self.prompts.append(user_prompt)
        return self._replies.pop(0)

    def chat_json_array(self, system_prompt: str, user_prompt: str) -> list:
        raise NotImplementedError


def test_resolve_one_confirms_top_candidate_via_adjudication(monkeypatch: pytest.MonkeyPatch) -> None:
    from insights.stages import discover as discover_mod

    work_item = WorkItem(tmdb_id=27205, type="movie", title="Inception", year=2010)

    monkeypatch.setattr(
        discover_mod,
        "_fetch_wikipedia_candidates",
        lambda wi: [SourceCandidate(title="Inception (2010 film)", url="https://w/inception")],
    )
    monkeypatch.setattr(
        discover_mod,
        "_fetch_fandom_candidates",
        lambda wi: ("inception", []),
    )

    chat_client = _FakeChatClient(["yes"])
    entry = discover_mod.resolve_one(work_item, chat_client)

    assert entry.status == "resolved"
    assert entry.wikipedia_url == "https://w/inception"
    assert entry.fandom_page_url is None


def test_resolve_one_skips_when_adjudication_says_no(monkeypatch: pytest.MonkeyPatch) -> None:
    from insights.stages import discover as discover_mod

    work_item = WorkItem(tmdb_id=1, type="movie", title="Ambiguous Title", year=2010)

    monkeypatch.setattr(
        discover_mod,
        "_fetch_wikipedia_candidates",
        lambda wi: [SourceCandidate(title="Ambiguous Title (wrong thing)", url="https://w/wrong")],
    )
    monkeypatch.setattr(discover_mod, "_fetch_fandom_candidates", lambda wi: ("x", []))

    chat_client = _FakeChatClient(["no"])
    entry = discover_mod.resolve_one(work_item, chat_client)

    assert entry.status == "ambiguous"
    assert entry.wikipedia_url is None


def test_resolve_one_no_candidates_is_no_match(monkeypatch: pytest.MonkeyPatch) -> None:
    from insights.stages import discover as discover_mod

    work_item = WorkItem(tmdb_id=1, type="movie", title="Totally Obscure", year=1950)

    monkeypatch.setattr(discover_mod, "_fetch_wikipedia_candidates", lambda wi: [])
    monkeypatch.setattr(discover_mod, "_fetch_fandom_candidates", lambda wi: ("x", []))

    chat_client = _FakeChatClient([])
    entry = discover_mod.resolve_one(work_item, chat_client)

    assert entry.status == "no_match"


def test_rank_fandom_landing_first_prefers_representative_page() -> None:
    # Fandom search surfaces in-universe pages ("Silo 18", a location) above the
    # landing page; the ranker must reorder so a show-representative page leads.
    w = WorkItem(tmdb_id=125988, type="tv", title="Silo", year=2023)
    cands = [
        SourceCandidate(title="Silo 18", url="https://silo.fandom.com/wiki/Silo_18"),
        SourceCandidate(title="Silo series", url="https://silo.fandom.com/wiki/Silo_series"),
        SourceCandidate(title="Silo Wiki", url="https://silo.fandom.com/wiki/Silo_Wiki"),
    ]
    ranked = rank_fandom_landing_first(cands, w)
    # "Silo series" (title-prefixed + series) must beat the in-universe "Silo 18".
    assert ranked[0].title == "Silo series"
    assert ranked[-1].title == "Silo 18"


def test_rank_fandom_landing_first_exact_title_wins() -> None:
    w = WorkItem(tmdb_id=1, type="tv", title="Fringe", year=2008)
    cands = [
        SourceCandidate(title="Walter Bishop", url="https://fringe.fandom.com/wiki/Walter_Bishop"),
        SourceCandidate(title="Fringe", url="https://fringe.fandom.com/wiki/Fringe"),
    ]
    ranked = rank_fandom_landing_first(cands, w)
    assert ranked[0].title == "Fringe"


def test_parse_wikipedia_query_extracts_orders_by_index_and_keeps_snippet() -> None:
    payload = {
        "query": {
            "pages": {
                "999": {"title": "Silo", "fullurl": "https://w/Silo", "extract": "A grain store.", "index": 1},
                "111": {"title": "Silo (TV series)", "fullurl": "https://w/Silo_TV",
                        "extract": "A 2023 dystopian series.", "index": 2},
            }
        }
    }
    cands = parse_wikipedia_query_extracts(payload)
    # Ordered by search index, snippets preserved.
    assert [c.title for c in cands] == ["Silo", "Silo (TV series)"]
    assert cands[1].snippet == "A 2023 dystopian series."


def test_parse_wikipedia_query_extracts_empty_payload() -> None:
    assert parse_wikipedia_query_extracts({}) == []
    assert parse_wikipedia_query_extracts({"query": {"pages": {}}}) == []
