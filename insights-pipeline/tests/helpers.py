"""Shared test helpers.

`make_config` builds a `Config` with every field at a sensible default
(mirroring `Config.from_env`'s documented defaults) so individual tests only
need to override the fields they actually care about, instead of every test
re-listing all fields by hand (which breaks every time a new tunable is
added — see the freshness/on-demand config knobs).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from insights.config import Config


def make_config(**overrides: Any) -> Config:
    defaults: dict[str, Any] = dict(
        llm_base_url="http://fake/v1",
        llm_model="gemma4:31b-it-q4_K_M",
        llm_timeout_secs=5.0,
        llm_max_retries=1,
        extract_model="test-extract",
        verify_model="test-verify",
        data_dir=Path("./data"),
        tmdb_proxy_base_url="https://tmdb-proxy.example",
        library_only=False,
        plex_base_url="",
        plex_token="",
        r2_endpoint_url="",
        r2_bucket="",
        r2_access_key_id="",
        r2_secret_access_key="",
        ondemand_poll_secs=120.0,
        ondemand_max_batch=8,
        scheduled_max_titles=200,
        settle_movie_days=90,
        settle_show_days=60,
        settle_episode_days=30,
        young_refresh_days=14,
        ttl_movie_days=180,
        ttl_show_days=45,
        ttl_episode_days=90,
    )
    defaults.update(overrides)
    return Config(**defaults)
