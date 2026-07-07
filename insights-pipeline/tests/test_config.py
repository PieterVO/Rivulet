"""Tests for `Config.from_env` — on-demand loop + age-aware freshness knobs.

All tunables are env-driven (never hardcoded); these tests pin the documented
defaults and confirm env overrides are honored.
"""

from __future__ import annotations


def test_freshness_and_loop_defaults(monkeypatch):
    for k in (
        "INSIGHTS_ONDEMAND_POLL_SECS",
        "INSIGHTS_ONDEMAND_MAX_BATCH",
        "INSIGHTS_SCHEDULED_MAX_TITLES",
        "INSIGHTS_YOUNG_REFRESH_DAYS",
        "INSIGHTS_SETTLE_MOVIE_DAYS",
        "INSIGHTS_SETTLE_SHOW_DAYS",
        "INSIGHTS_SETTLE_EPISODE_DAYS",
        "INSIGHTS_TTL_MOVIE_DAYS",
        "INSIGHTS_TTL_SHOW_DAYS",
        "INSIGHTS_TTL_EPISODE_DAYS",
    ):
        monkeypatch.delenv(k, raising=False)
    from insights.config import Config

    c = Config.from_env()
    assert c.ondemand_poll_secs == 120.0
    assert c.ondemand_max_batch == 8
    assert c.scheduled_max_titles == 200
    assert c.young_refresh_days == 14
    assert (c.settle_movie_days, c.settle_show_days, c.settle_episode_days) == (90, 60, 30)
    assert (c.ttl_movie_days, c.ttl_show_days, c.ttl_episode_days) == (180, 45, 90)


def test_freshness_env_override(monkeypatch):
    monkeypatch.setenv("INSIGHTS_ONDEMAND_POLL_SECS", "45")
    monkeypatch.setenv("INSIGHTS_TTL_MOVIE_DAYS", "365")
    from insights.config import Config

    c = Config.from_env()
    assert c.ondemand_poll_secs == 45.0
    assert c.ttl_movie_days == 365
