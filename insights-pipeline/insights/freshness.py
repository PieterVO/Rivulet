"""Age-aware freshness: decide whether a published object should be re-generated.

Pure module — no IO, no wall clock. `now` is passed in. The refresh interval
is a function of the title's own age: young titles (still accreting coverage on
Wikipedia/Fandom) refresh often; once past the settle window they drop to a long
mature TTL. A pipeline-version bump forces staleness so schema/prompt upgrades
re-run everything. Corrupt/absent dates fail conservative (not stale) so bad data
never causes churn.
"""

from __future__ import annotations

from datetime import date, datetime, timezone
from typing import Literal

from insights.config import Config

MediaKind = Literal["movie", "show", "episode"]


def object_kind(type_field: str) -> MediaKind:
    return "episode" if type_field == "episode" else ("show" if type_field == "show" else "movie")


def _settle_days(kind: MediaKind, config: Config) -> int:
    return {
        "movie": config.settle_movie_days,
        "show": config.settle_show_days,
        "episode": config.settle_episode_days,
    }[kind]


def _mature_ttl_days(kind: MediaKind, config: Config) -> int:
    return {
        "movie": config.ttl_movie_days,
        "show": config.ttl_show_days,
        "episode": config.ttl_episode_days,
    }[kind]


def refresh_interval_days(kind: MediaKind, age_days: int, config: Config) -> int:
    """Young (age < settle window) -> young_refresh; else the mature TTL."""
    if age_days < _settle_days(kind, config):
        return config.young_refresh_days
    return _mature_ttl_days(kind, config)


def _parse_dt(s: str) -> datetime | None:
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _parse_date(s: str | None) -> date | None:
    if not s:
        return None
    try:
        return date.fromisoformat(s[:10])
    except (ValueError, TypeError):
        return None


def is_stale(
    *,
    generated_at: str,
    release_date: str | None,
    kind: MediaKind,
    now: datetime,
    config: Config,
    pipeline_version: int,
    current_pipeline_version: int,
) -> bool:
    if pipeline_version != current_pipeline_version:
        return True
    gen = _parse_dt(generated_at)
    if gen is None:
        return False  # corrupt timestamp: don't churn
    rel = _parse_date(release_date)
    age_days = (now.date() - rel).days if rel is not None else _settle_days(kind, config)
    interval = refresh_interval_days(kind, max(age_days, 0), config)
    return (now - gen).days > interval
