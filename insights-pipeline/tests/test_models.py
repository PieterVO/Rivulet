"""Tests for the pipeline schema dataclasses + fact_id stability."""

from __future__ import annotations

from insights.models import Fact, Source, TitleTrivia, fact_id


def test_fact_id_is_stable_across_whitespace() -> None:
    a = fact_id("Nolan wrote the draft over nine years.", "https://w/Inception")
    b = fact_id("  Nolan wrote the draft over nine years.  ", "https://w/Inception ")
    assert a == b
    assert a.startswith("f_")


def test_fact_id_changes_with_text_or_source() -> None:
    base = fact_id("A fact.", "https://w/x")
    assert fact_id("A different fact.", "https://w/x") != base
    assert fact_id("A fact.", "https://w/y") != base


def test_fact_validity() -> None:
    good = Fact("Some fact.", "production", 0, Source("Wikipedia", "https://w/x"))
    assert good.is_valid()
    assert Fact("", "production", 0, Source("W", "https://w/x")).is_valid() is False
    assert Fact("t", "bogus", 0, Source("W", "https://w/x")).is_valid() is False
    assert Fact("t", "production", 5, Source("W", "https://w/x")).is_valid() is False
    assert Fact("t", "production", 0, Source("W", "")).is_valid() is False


def test_published_dict_strips_source_snippet() -> None:
    f = Fact(
        "A fact.",
        "casting",
        1,
        Source("Fandom", "https://fandom/x"),
        source_snippet="The original sentence.",
    )
    pub = f.to_published_dict()
    assert "source_snippet" not in pub
    assert pub["id"] == f.id
    assert pub["source"] == {"name": "Fandom", "url": "https://fandom/x"}
    # Working dict keeps the snippet for the verify stage.
    assert f.to_working_dict()["source_snippet"] == "The original sentence."


def test_fact_working_dict_round_trip() -> None:
    f = Fact("A fact.", "lore", 2, Source("Fandom", "https://f/x"), source_snippet="s")
    again = Fact.from_working_dict(f.to_working_dict())
    assert again == f


def test_title_trivia_published_shape_matches_client_schema() -> None:
    trivia = TitleTrivia(
        id="tmdb://27205",
        type="movie",
        generated_at="2026-07-07T00:00:00Z",
        pipeline_version=1,
        attribution=[Source("Wikipedia", "https://en.wikipedia.org/wiki/Inception")],
        facts=[Fact("A fact.", "production", 0, Source("Wikipedia", "https://w/x"))],
    )
    d = trivia.to_published_dict()
    # Keys must match the Swift TitleTrivia/TriviaFact CodingKeys exactly.
    assert set(d.keys()) == {
        "id",
        "type",
        "generatedAt",
        "pipelineVersion",
        "covered",
        "releaseDate",
        "attribution",
        "facts",
    }
    assert set(d["facts"][0].keys()) == {"id", "text", "category", "spoiler", "source"}


def test_published_dict_includes_covered_and_release_date() -> None:
    t = TitleTrivia(
        id="tmdb://27205",
        type="movie",
        generated_at="2026-07-07T00:00:00Z",
        pipeline_version=1,
        covered=True,
        release_date="2010-07-16",
    )
    d = t.to_published_dict()
    assert d["covered"] is True
    assert d["releaseDate"] == "2010-07-16"


def test_covered_and_release_date_default() -> None:
    # Existing construction sites (pre-tombstone) don't pass these -- must
    # default to covered=True, release_date=None so older callers keep working.
    t = TitleTrivia(
        id="tmdb://1",
        type="movie",
        generated_at="2026-07-07T00:00:00Z",
        pipeline_version=1,
    )
    assert t.covered is True
    assert t.release_date is None


def test_tombstone_is_covered_false_empty() -> None:
    t = TitleTrivia.tombstone(
        id="tmdb://999",
        type="movie",
        generated_at="2026-07-07T00:00:00Z",
        pipeline_version=1,
        release_date="2025-01-01",
    )
    assert t.covered is False
    assert t.facts == []
    assert t.attribution == []
    d = t.to_published_dict()
    assert d["covered"] is False
    assert d["releaseDate"] == "2025-01-01"
    assert d["facts"] == []
