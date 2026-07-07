"""Tests for the fetch stage's pure section-selection + wikitext cleanup,
plus the disk-cache path, against a real fixture wikitext file.

No live MediaWiki calls: `fetch_page_cached` is exercised with a
monkeypatched `_fetch_wikitext` so the cache-hit/cache-miss behavior is
still exercised end-to-end.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from insights.stages.fetch import (
    FetchedPage,
    WikiSection,
    cache_key_for_url,
    fetch_page_cached,
    is_wanted_section,
    parse_wikitext_sections,
    select_sections,
    strip_wiki_markup,
)

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "sample_wikitext.txt"


def load_fixture() -> str:
    return FIXTURE_PATH.read_text(encoding="utf-8")


def test_is_wanted_section() -> None:
    assert is_wanted_section("Production")
    assert is_wanted_section("Casting")
    assert is_wanted_section("Cast")
    assert is_wanted_section("Reception")
    assert not is_wanted_section("Plot")
    assert not is_wanted_section("References")
    assert not is_wanted_section("External links")


def test_is_wanted_section_excluded_beats_substring_match() -> None:
    # "See also" contains no wanted keyword, but be defensive: a heading
    # like "Production references" should still be excluded.
    assert not is_wanted_section("Production references")


def test_parse_wikitext_sections_fixture() -> None:
    wikitext = load_fixture()
    sections = parse_wikitext_sections(wikitext, "Example Film")

    headings = [s.heading for s in sections]
    assert headings == [
        "Example Film",  # implicit lead section
        "Plot",
        "Production",
        "Casting",
        "Reception",
        "References",
        "External links",
    ]
    # Casting is a level-3 (===) subsection under Production.
    casting = next(s for s in sections if s.heading == "Casting")
    assert casting.level == 3
    production = next(s for s in sections if s.heading == "Production")
    assert production.level == 2


def test_parse_wikitext_sections_no_headings_is_all_lead() -> None:
    sections = parse_wikitext_sections("Just some prose, no headings at all.", "Title")
    assert len(sections) == 1
    assert sections[0].heading == "Title"


def test_select_sections_filters_fixture_to_wanted_only() -> None:
    wikitext = load_fixture()
    all_sections = parse_wikitext_sections(wikitext, "Example Film")
    wanted = select_sections(all_sections)

    headings = {s.heading for s in wanted}
    # Production, Casting, Reception kept; lead/Plot/References/External
    # links dropped (lead has no wanted keyword match; Plot isn't in our
    # keyword list; References/External links explicitly excluded).
    assert headings == {"Production", "Casting", "Reception"}


def test_select_sections_drops_empty_body() -> None:
    sections = [WikiSection(heading="Production", level=2, body="")]
    assert select_sections(sections) == []


def test_strip_wiki_markup_removes_refs_templates_links_and_bold() -> None:
    raw = (
        "The film was shot in Iceland over six weeks.<ref name=\"iceland\">cite</ref>\n"
        "The director insisted on practical effects rather than CGI. "
        "See [https://example.com/interview interview] for details. "
        "{{cite web|title=irrelevant template}}\n"
        "'''Jane Doe''' plays [[Some Character|the protagonist]]."
    )
    cleaned = strip_wiki_markup(raw)

    assert "<ref" not in cleaned
    assert "{{" not in cleaned
    assert "cite web" not in cleaned
    assert "[[" not in cleaned
    assert "'''" not in cleaned
    assert "Iceland over six weeks" in cleaned
    assert "interview" in cleaned
    assert "Jane Doe plays the protagonist." in cleaned


def test_strip_wiki_markup_collapses_blank_lines() -> None:
    raw = "Line one.\n\n\n\n\nLine two."
    cleaned = strip_wiki_markup(raw)
    assert "\n\n\n" not in cleaned


def test_strip_wiki_markup_strips_html_comments_and_tags() -> None:
    raw = "Visible text.<!-- a hidden editorial note --><br/>More text."
    cleaned = strip_wiki_markup(raw)
    assert "hidden editorial note" not in cleaned
    assert "<br" not in cleaned


def test_cache_key_for_url_is_stable_and_filename_safe() -> None:
    key_a = cache_key_for_url("https://en.wikipedia.org/wiki/Inception")
    key_b = cache_key_for_url("https://en.wikipedia.org/wiki/Inception")
    key_c = cache_key_for_url("https://en.wikipedia.org/wiki/Interstellar")
    assert key_a == key_b
    assert key_a != key_c
    assert key_a.endswith(".wikitext")
    assert "/" not in key_a


def test_fetch_page_cached_cache_hit_skips_network(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from insights.stages import fetch as fetch_mod

    def fail_if_called(url: str, *, rate_limit_secs: float = 0.5) -> str | None:
        raise AssertionError("network fetch should not be called on a cache hit")

    monkeypatch.setattr(fetch_mod, "_fetch_wikitext", fail_if_called)

    url = "https://en.wikipedia.org/wiki/Example_Film"
    cache_path = tmp_path / cache_key_for_url(url)
    cache_path.write_text(load_fixture(), encoding="utf-8")

    page = fetch_page_cached(url, tmp_path)

    assert page is not None
    assert isinstance(page, FetchedPage)
    assert {s.heading for s in page.sections} == {"Production", "Casting", "Reception"}


def test_fetch_page_cached_cache_miss_writes_cache(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from insights.stages import fetch as fetch_mod

    calls = []

    def fake_fetch(url: str, *, rate_limit_secs: float = 0.5) -> str | None:
        calls.append(url)
        return load_fixture()

    monkeypatch.setattr(fetch_mod, "_fetch_wikitext", fake_fetch)

    url = "https://en.wikipedia.org/wiki/Example_Film"
    page = fetch_page_cached(url, tmp_path)

    assert len(calls) == 1
    assert page is not None
    cache_path = tmp_path / cache_key_for_url(url)
    assert cache_path.exists()

    # Second call is a cache hit — no second network call.
    page_again = fetch_page_cached(url, tmp_path)
    assert len(calls) == 1
    assert page_again is not None


def test_fetch_page_cached_returns_none_when_fetch_fails(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from insights.stages import fetch as fetch_mod

    monkeypatch.setattr(fetch_mod, "_fetch_wikitext", lambda url, **kw: None)

    url = "https://en.wikipedia.org/wiki/Nonexistent_Page"
    page = fetch_page_cached(url, tmp_path)
    assert page is None
