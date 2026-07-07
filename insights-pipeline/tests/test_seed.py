"""Tests for the seed stage's pure list-building logic.

No network/disk IO here except for the tiny jsonl read/write helpers, which
are exercised against tmp_path fixtures rather than the real data dir.
"""

from __future__ import annotations

import json
from pathlib import Path

from insights.stages.seed import (
    WorkItem,
    build_seed_list,
    load_recurate_list,
    parse_plex_library_response,
    parse_tmdb_list_response,
    write_seed_jsonl,
)


def test_work_item_key_dedup_movie_vs_episode() -> None:
    movie = WorkItem(tmdb_id=1, type="movie", title="A", year=2020)
    ep = WorkItem(tmdb_id=1, type="tv", title="A", year=2020, season=1, episode=2)
    assert movie.key == "movie:1"
    assert ep.key == "tv:1:S1E2"
    assert movie.key != ep.key


def test_build_seed_list_intersects_tmdb_with_plex_library() -> None:
    tmdb_candidates = [
        WorkItem(tmdb_id=1, type="movie", title="In Library", year=2020, reason="popular"),
        WorkItem(tmdb_id=2, type="movie", title="Not In Library", year=2021, reason="popular"),
        WorkItem(tmdb_id=3, type="tv", title="Show In Library", year=2019, reason="trending"),
    ]
    plex_ids = {("movie", 1), ("tv", 3)}

    result = build_seed_list([], tmdb_candidates, plex_ids)

    assert [i.tmdb_id for i in result] == [1, 3]
    assert all(i.reason in ("popular", "trending") for i in result)


def test_build_seed_list_recurate_items_go_first_and_bypass_library_check() -> None:
    recurate = [WorkItem(tmdb_id=99, type="movie", title="Reported Title", year=2018)]
    tmdb_candidates = [WorkItem(tmdb_id=1, type="movie", title="Popular", year=2020)]
    plex_ids = {("movie", 1)}  # note: 99 is NOT in the library dump

    result = build_seed_list(recurate, tmdb_candidates, plex_ids)

    assert [i.tmdb_id for i in result] == [99, 1]


def test_build_seed_list_dedups_recurate_over_tmdb_duplicate() -> None:
    recurate = [
        WorkItem(tmdb_id=1, type="movie", title="Dup", year=2020, reason="recurate")
    ]
    tmdb_candidates = [
        WorkItem(tmdb_id=1, type="movie", title="Dup", year=2020, reason="popular"),
    ]
    plex_ids = {("movie", 1)}

    result = build_seed_list(recurate, tmdb_candidates, plex_ids)

    assert len(result) == 1
    assert result[0].reason == "recurate"


def test_build_seed_list_popular_beats_trending_duplicate() -> None:
    tmdb_candidates = [
        WorkItem(tmdb_id=1, type="movie", title="Dup", year=2020, reason="popular"),
        WorkItem(tmdb_id=1, type="movie", title="Dup", year=2020, reason="trending"),
    ]
    plex_ids = {("movie", 1)}

    result = build_seed_list([], tmdb_candidates, plex_ids)

    assert len(result) == 1
    assert result[0].reason == "popular"


def test_build_seed_list_empty_library_yields_empty_list() -> None:
    tmdb_candidates = [WorkItem(tmdb_id=1, type="movie", title="X", year=2020)]
    assert build_seed_list([], tmdb_candidates, set()) == []


def test_parse_tmdb_list_response_movie() -> None:
    payload = {
        "results": [
            {"id": 27205, "title": "Inception", "release_date": "2010-07-16"},
            {"id": 42, "title": "No Year"},
            {"title": "Missing Id"},
            {"id": 7},  # missing title
        ]
    }
    items = parse_tmdb_list_response(payload, "movie", reason="popular")
    assert len(items) == 2
    assert items[0] == WorkItem(
        tmdb_id=27205, type="movie", title="Inception", year=2010, reason="popular"
    )
    assert items[1].year is None


def test_parse_tmdb_list_response_tv_uses_name_and_first_air_date() -> None:
    payload = {"results": [{"id": 5, "name": "Silo", "first_air_date": "2023-05-05"}]}
    items = parse_tmdb_list_response(payload, "tv", reason="trending")
    assert items == [WorkItem(tmdb_id=5, type="tv", title="Silo", year=2023, reason="trending")]


def test_parse_plex_library_response_maps_show_to_tv_and_reads_guids() -> None:
    payload = {
        "MediaContainer": {
            "Metadata": [
                {
                    "type": "movie",
                    "Guid": [{"id": "imdb://tt1375666"}, {"id": "tmdb://27205"}],
                },
                {"type": "show", "Guid": [{"id": "tmdb://2802"}]},
                {"type": "movie", "Guid": []},  # no tmdb guid -> excluded
                {"type": "artist", "Guid": [{"id": "tmdb://999"}]},  # wrong type -> excluded
            ]
        }
    }
    result = parse_plex_library_response(payload)
    assert result == {("movie", 27205), ("tv", 2802)}


def test_load_recurate_list_missing_file_returns_empty(tmp_path: Path) -> None:
    assert load_recurate_list(tmp_path / "nope.jsonl") == []


def test_load_recurate_list_reads_jsonl_and_tags_reason(tmp_path: Path) -> None:
    path = tmp_path / "recurate.jsonl"
    path.write_text(
        json.dumps(
            {"tmdb_id": 1, "type": "movie", "title": "Reported", "year": 2020, "reason": "popular"}
        )
        + "\n",
        encoding="utf-8",
    )
    items = load_recurate_list(path)
    assert len(items) == 1
    assert items[0].reason == "recurate"  # always forced regardless of stored reason


def test_write_seed_jsonl_round_trips(tmp_path: Path) -> None:
    items = [
        WorkItem(tmdb_id=1, type="movie", title="A", year=2020, reason="recurate"),
        WorkItem(tmdb_id=2, type="tv", title="B", year=2021, season=1, episode=3, reason="popular"),
    ]
    out_path = tmp_path / "seed.jsonl"
    write_seed_jsonl(items, out_path)

    lines = out_path.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 2
    round_tripped = [WorkItem.from_dict(json.loads(line)) for line in lines]
    assert round_tripped == items
