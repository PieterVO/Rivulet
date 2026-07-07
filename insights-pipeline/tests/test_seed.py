"""Tests for the seed stage's pure list-building logic.

No network/disk IO here except for the tiny jsonl read/write helpers, which
are exercised against tmp_path fixtures rather than the real data dir.
"""

from __future__ import annotations

import json
from datetime import date, datetime, timezone
from pathlib import Path

from insights.stages.seed import (
    WorkItem,
    append_published_keys,
    build_episode_work_items,
    build_scheduled_seed_list,
    build_seed_list,
    load_published_keys,
    load_published_records,
    load_recurate_list,
    parse_plex_library_response,
    parse_tmdb_list_response,
    parse_tmdb_season_response,
    stale_workitems_from_records,
    write_seed_jsonl,
)
from tests.helpers import make_config


def _cfg(**over):
    return make_config(**over)


def test_work_item_key_dedup_movie_vs_episode() -> None:
    movie = WorkItem(tmdb_id=1, type="movie", title="A", year=2020)
    ep = WorkItem(tmdb_id=1, type="tv", title="A", year=2020, season=1, episode=2)
    assert movie.key == "movie:1"
    assert ep.key == "tv:1:S1E2"
    assert movie.key != ep.key


def test_build_seed_list_popular_only_keeps_all_candidates_when_library_is_none() -> None:
    # Popular-only mode (the default): no library filter, every TMDB candidate
    # is kept regardless of ownership. This is the no-Plex path.
    tmdb_candidates = [
        WorkItem(tmdb_id=1, type="movie", title="A", year=2020, reason="popular"),
        WorkItem(tmdb_id=2, type="movie", title="B", year=2021, reason="popular"),
        WorkItem(tmdb_id=3, type="tv", title="C", year=2019, reason="trending"),
    ]
    result = build_seed_list([], tmdb_candidates, None)
    assert [i.tmdb_id for i in result] == [1, 2, 3]


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
        tmdb_id=27205,
        type="movie",
        title="Inception",
        year=2010,
        reason="popular",
        release_date="2010-07-16",
    )
    assert items[1].year is None


def test_parse_tmdb_list_response_tv_uses_name_and_first_air_date() -> None:
    payload = {"results": [{"id": 5, "name": "Silo", "first_air_date": "2023-05-05"}]}
    items = parse_tmdb_list_response(payload, "tv", reason="trending")
    assert items == [
        WorkItem(
            tmdb_id=5, type="tv", title="Silo", year=2023, reason="trending", release_date="2023-05-05"
        )
    ]


def test_list_parse_keeps_full_release_date() -> None:
    payload = {"results": [{"id": 27205, "title": "Inception", "release_date": "2010-07-16"}]}
    items = parse_tmdb_list_response(payload, media_type="movie", reason="popular")
    assert items[0].release_date == "2010-07-16"
    assert items[0].year == 2010


def test_season_parse_keeps_air_date() -> None:
    payload = {
        "episodes": [{"episode_number": 1, "season_number": 1, "air_date": "2023-05-05"}]
    }
    items = parse_tmdb_season_response(
        payload, tmdb_id=125988, show_title="Silo", show_year=2023, today=date(2026, 7, 7)
    )
    assert items[0].release_date == "2023-05-05"


def test_workitem_release_date_roundtrips() -> None:
    w = WorkItem(tmdb_id=1, type="movie", title="X", year=2020, release_date="2020-02-02")
    assert WorkItem.from_dict(w.to_dict()).release_date == "2020-02-02"


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


# --- parse_tmdb_season_response (episode enumeration) ---


def test_parse_tmdb_season_response_builds_episode_work_items_for_aired_episodes() -> None:
    payload = {
        "episodes": [
            {"episode_number": 1, "season_number": 1, "name": "Pilot", "air_date": "2023-05-05"},
            {"episode_number": 2, "season_number": 1, "name": "Ep 2", "air_date": "2023-05-12"},
        ]
    }
    items = parse_tmdb_season_response(
        payload, tmdb_id=2802, show_title="Silo", show_year=2023, today=date(2023, 6, 1)
    )
    assert items == [
        WorkItem(
            tmdb_id=2802,
            type="tv",
            title="Silo",
            year=2023,
            season=1,
            episode=1,
            reason="episode",
            release_date="2023-05-05",
        ),
        WorkItem(
            tmdb_id=2802,
            type="tv",
            title="Silo",
            year=2023,
            season=1,
            episode=2,
            reason="episode",
            release_date="2023-05-12",
        ),
    ]


def test_parse_tmdb_season_response_skips_future_episodes() -> None:
    payload = {
        "episodes": [
            {"episode_number": 1, "season_number": 2, "air_date": "2023-05-05"},
            {"episode_number": 2, "season_number": 2, "air_date": "2099-01-01"},  # not aired yet
        ]
    }
    items = parse_tmdb_season_response(
        payload, tmdb_id=1, show_title="X", show_year=None, today=date(2023, 6, 1)
    )
    assert [i.episode for i in items] == [1]


def test_parse_tmdb_season_response_skips_episodes_missing_air_date() -> None:
    payload = {"episodes": [{"episode_number": 3, "season_number": 1}]}  # no air_date at all
    items = parse_tmdb_season_response(
        payload, tmdb_id=1, show_title="X", show_year=None, today=date(2023, 6, 1)
    )
    assert items == []


def test_parse_tmdb_season_response_skips_malformed_air_date() -> None:
    payload = {"episodes": [{"episode_number": 1, "season_number": 1, "air_date": "not-a-date"}]}
    items = parse_tmdb_season_response(
        payload, tmdb_id=1, show_title="X", show_year=None, today=date(2023, 6, 1)
    )
    assert items == []


def test_parse_tmdb_season_response_skips_entries_missing_episode_number() -> None:
    payload = {"episodes": [{"season_number": 1, "air_date": "2023-01-01"}]}  # missing episode_number
    items = parse_tmdb_season_response(
        payload, tmdb_id=1, show_title="X", show_year=None, today=date(2023, 6, 1)
    )
    assert items == []


def test_parse_tmdb_season_response_boundary_air_date_equals_today_has_aired() -> None:
    payload = {"episodes": [{"episode_number": 1, "season_number": 1, "air_date": "2023-06-01"}]}
    items = parse_tmdb_season_response(
        payload, tmdb_id=1, show_title="X", show_year=None, today=date(2023, 6, 1)
    )
    assert len(items) == 1


# --- build_episode_work_items (freshness / re-seed idempotency) ---


def test_build_episode_work_items_expands_show_level_items_only() -> None:
    show_item = WorkItem(tmdb_id=1, type="tv", title="Silo", year=2023)  # show-level, no season/episode
    movie_item = WorkItem(tmdb_id=2, type="movie", title="A Movie", year=2020)
    already_episode_item = WorkItem(
        tmdb_id=3, type="tv", title="Other Show", year=2021, season=1, episode=1
    )
    ep1 = WorkItem(tmdb_id=1, type="tv", title="Silo", year=2023, season=1, episode=1, reason="episode")
    episodes_by_show = {1: [ep1], 3: [ep1]}  # show 3's episodes should never surface: not show-level

    result = build_episode_work_items(
        [show_item, movie_item, already_episode_item], episodes_by_show, published_keys=set()
    )

    assert result == [ep1]


def test_build_episode_work_items_skips_already_published_episodes() -> None:
    show_item = WorkItem(tmdb_id=1, type="tv", title="Silo", year=2023)
    ep1 = WorkItem(tmdb_id=1, type="tv", title="Silo", year=2023, season=1, episode=1, reason="episode")
    ep2 = WorkItem(tmdb_id=1, type="tv", title="Silo", year=2023, season=1, episode=2, reason="episode")
    episodes_by_show = {1: [ep1, ep2]}

    result = build_episode_work_items(
        [show_item], episodes_by_show, published_keys={ep1.key}
    )

    assert result == [ep2]  # ep1 already published; only the new episode is enqueued -- re-seed idempotency


def test_build_episode_work_items_dedups_repeated_episode_entries() -> None:
    show_item = WorkItem(tmdb_id=1, type="tv", title="Silo", year=2023)
    ep1 = WorkItem(tmdb_id=1, type="tv", title="Silo", year=2023, season=1, episode=1, reason="episode")
    episodes_by_show = {1: [ep1, ep1]}  # duplicate entry (e.g. overlapping season fetches)

    result = build_episode_work_items([show_item], episodes_by_show, published_keys=set())

    assert result == [ep1]


def test_build_episode_work_items_no_shows_yields_empty() -> None:
    movie_item = WorkItem(tmdb_id=1, type="movie", title="X", year=2020)
    assert build_episode_work_items([movie_item], {}, published_keys=set()) == []


# --- published.jsonl manifest ---


def test_load_published_keys_missing_file_returns_empty_set(tmp_path: Path) -> None:
    assert load_published_keys(tmp_path / "nope.jsonl") == set()


def test_append_and_load_published_keys_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "published.jsonl"
    append_published_keys(
        [{"key": "movie:1"}, {"key": "tv:2:S1E1"}], path, published_at="2026-07-07T00:00:00Z"
    )

    assert load_published_keys(path) == {"movie:1", "tv:2:S1E1"}


def test_append_published_keys_appends_across_multiple_calls(tmp_path: Path) -> None:
    path = tmp_path / "published.jsonl"
    append_published_keys([{"key": "movie:1"}], path, published_at="2026-07-07T00:00:00Z")
    append_published_keys([{"key": "tv:2:S1E1"}], path, published_at="2026-07-08T00:00:00Z")

    assert load_published_keys(path) == {"movie:1", "tv:2:S1E1"}
    assert len(path.read_text(encoding="utf-8").splitlines()) == 2


def test_append_published_keys_empty_list_is_noop_and_does_not_create_file(tmp_path: Path) -> None:
    path = tmp_path / "published.jsonl"
    append_published_keys([], path, published_at="2026-07-07T00:00:00Z")
    assert not path.exists()


def test_load_published_keys_skips_malformed_lines(tmp_path: Path) -> None:
    path = tmp_path / "published.jsonl"
    path.write_text(
        'not valid json\n{"key": "movie:1", "published_at": "2026-07-07T00:00:00Z"}\n{"no_key": true}\n',
        encoding="utf-8",
    )
    assert load_published_keys(path) == {"movie:1"}


def test_manifest_records_roundtrip(tmp_path: Path) -> None:
    p = tmp_path / "published.jsonl"
    rec = {
        "key": "movie:27205",
        "type": "movie",
        "tmdb_id": 27205,
        "title": "Inception",
        "year": 2010,
        "release_date": "2010-07-16",
        "covered": True,
    }
    append_published_keys([rec], p, published_at="2026-07-07T00:00:00Z")
    assert "movie:27205" in load_published_keys(p)
    recs = load_published_records(p)
    assert recs[0]["release_date"] == "2010-07-16"
    assert recs[0]["published_at"] == "2026-07-07T00:00:00Z"


def test_load_published_keys_tolerates_old_format(tmp_path: Path) -> None:
    p = tmp_path / "published.jsonl"
    p.write_text('{"key": "movie:1", "published_at": "2026-01-01T00:00:00Z"}\n', encoding="utf-8")
    assert load_published_keys(p) == {"movie:1"}


# --- scheduled seed: TTL refresh + priority ordering + cap (Task 7) ---


def _w(id, **kw):
    return WorkItem(
        tmdb_id=id,
        type=kw.get("type", "movie"),
        title=str(id),
        year=2020,
        **{k: v for k, v in kw.items() if k != "type"},
    )


def test_priority_order_and_dedup() -> None:
    stale = [_w(1)]
    new_ep = [_w(2, type="tv", season=1, episode=1)]
    popular = [_w(1), _w(3)]  # _w(1) dup of stale -> dropped
    out = build_scheduled_seed_list(
        stale_items=stale, new_episode_items=new_ep, popular_items=popular, max_titles=10
    )
    assert [w.tmdb_id for w in out] == [1, 2, 3]


def test_cap_applied() -> None:
    stale = [_w(i) for i in range(50)]
    out = build_scheduled_seed_list(
        stale_items=stale, new_episode_items=[], popular_items=[], max_titles=5
    )
    assert len(out) == 5


def test_stale_selection_from_records() -> None:
    now = datetime(2026, 7, 7, tzinfo=timezone.utc)
    records = [
        {
            "key": "movie:1",
            "type": "movie",
            "tmdb_id": 1,
            "title": "A",
            "year": 2026,
            "release_date": "2026-06-17",
            "covered": True,
            "published_at": "2026-06-22T00:00:00Z",
            "pipeline_version": 1,
        },  # young, 15d old -> stale
        {
            "key": "movie:2",
            "type": "movie",
            "tmdb_id": 2,
            "title": "B",
            "year": 2020,
            "release_date": "2020-01-01",
            "covered": True,
            "published_at": "2026-07-06T00:00:00Z",
            "pipeline_version": 1,
        },  # mature, 1d old -> fresh
    ]
    out = stale_workitems_from_records(records, now=now, config=_cfg(), current_pipeline_version=1)
    assert [w.tmdb_id for w in out] == [1]
