"""Tests for the age-aware freshness pure core (`insights/freshness.py`).

No wall clock: `now` is always passed in explicitly.
"""

from __future__ import annotations

from datetime import datetime, timezone

from insights.freshness import is_stale, refresh_interval_days
from tests.helpers import make_config


def _cfg(**over):
    return make_config(**over)


NOW = datetime(2026, 7, 7, tzinfo=timezone.utc)


def test_young_movie_uses_young_refresh():
    # released 20 days ago -> young (settle 90) -> refresh every 14
    assert refresh_interval_days("movie", age_days=20, config=_cfg()) == 14


def test_mature_movie_uses_mature_ttl():
    assert refresh_interval_days("movie", age_days=400, config=_cfg()) == 180


def test_young_movie_stale_after_14_days():
    # generated 15 days ago, released 20 days ago (young) -> stale
    assert is_stale(
        generated_at="2026-06-22T00:00:00Z",
        release_date="2026-06-17",
        kind="movie",
        now=NOW,
        config=_cfg(),
        pipeline_version=1,
        current_pipeline_version=1,
    ) is True


def test_young_movie_fresh_within_14_days():
    assert is_stale(
        generated_at="2026-07-01T00:00:00Z",
        release_date="2026-06-17",
        kind="movie",
        now=NOW,
        config=_cfg(),
        pipeline_version=1,
        current_pipeline_version=1,
    ) is False


def test_mature_movie_fresh_within_180_days():
    assert is_stale(
        generated_at="2026-05-01T00:00:00Z",
        release_date="2020-01-01",
        kind="movie",
        now=NOW,
        config=_cfg(),
        pipeline_version=1,
        current_pipeline_version=1,
    ) is False


def test_missing_release_date_treated_mature():
    # no release date -> mature interval (180 for movie); generated 30d ago -> fresh
    assert is_stale(
        generated_at="2026-06-07T00:00:00Z",
        release_date=None,
        kind="movie",
        now=NOW,
        config=_cfg(),
        pipeline_version=1,
        current_pipeline_version=1,
    ) is False


def test_pipeline_version_bump_forces_stale():
    assert is_stale(
        generated_at="2026-07-06T00:00:00Z",
        release_date="2020-01-01",
        kind="movie",
        now=NOW,
        config=_cfg(),
        pipeline_version=1,
        current_pipeline_version=2,
    ) is True


def test_unparseable_dates_not_stale():
    # defensive: bad generated_at -> not stale (don't churn on corrupt data)
    assert is_stale(
        generated_at="garbage",
        release_date="2020-01-01",
        kind="movie",
        now=NOW,
        config=_cfg(),
        pipeline_version=1,
        current_pipeline_version=1,
    ) is False
