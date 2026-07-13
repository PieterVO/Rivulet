"""Pipeline configuration — all runtime settings from env, never hardcoded.

The pipeline is model-agnostic via an OpenAI-compatible endpoint (Ollama by
default). R2 credentials and the Plex library-dump access come from env too.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

PIPELINE_VERSION = 2


@dataclass(frozen=True, slots=True)
class Config:
    # LLM (OpenAI-compatible; Ollama default). The bake-off picks the model.
    llm_base_url: str
    llm_model: str
    llm_timeout_secs: float
    llm_max_retries: int
    # Per-stage model overrides (default to llm_model when unset). Extract needs
    # the strong model (gemma4) for spoiler-safe tagging; verify + discover
    # adjudication are grounding/yes-no checks a faster model handles well.
    extract_model: str
    verify_model: str

    # On-demand loop + scheduling cadence.
    ondemand_poll_secs: float
    ondemand_max_batch: int
    scheduled_max_titles: int
    # How often the long-lived worker's scheduled source re-evaluates
    # stale/new-episode/popular work (re-runs seed.run()) once its in-memory
    # batch has been drained one title at a time.
    reseed_interval_secs: float
    # Age-aware freshness (see freshness.py). Settle window per type; a single
    # young-refresh interval while young; per-type mature TTL once settled.
    settle_movie_days: int
    settle_show_days: int
    settle_episode_days: int
    young_refresh_days: int
    ttl_movie_days: int
    ttl_show_days: int
    ttl_episode_days: int

    # Where each stage reads/writes its on-disk output.
    data_dir: Path

    # TMDB access is via the existing tmdb-proxy Worker (don't re-implement).
    tmdb_proxy_base_url: str

    # Seed scope. False (default) = popular-only: cover all TMDB popular/
    # trending content, no Plex needed. True = intersect with a Plex library.
    library_only: bool

    # Plex library dump — only used when library_only is True.
    plex_base_url: str
    plex_token: str

    # R2 (S3-compatible). Empty until the user enables R2; publish stage
    # checks for these and errors clearly if unset.
    r2_endpoint_url: str
    r2_bucket: str
    r2_access_key_id: str
    r2_secret_access_key: str

    # The tmdb-proxy Worker requires App Attest from the app. This pipeline is
    # a server: no Secure Enclave, so it cannot attest and authenticates with a
    # shared secret instead. That is safe HERE (and nowhere else) because the
    # machine is ours and the secret never ships to a user.
    #
    # Defaults to empty (send no header), which still works while the Worker is
    # in "observe" mode. It MUST be set before the Worker flips to "enforce",
    # or the seed stage loses TMDB access.
    tmdb_proxy_server_key: str = ""

    @property
    def r2_configured(self) -> bool:
        return bool(
            self.r2_endpoint_url
            and self.r2_bucket
            and self.r2_access_key_id
            and self.r2_secret_access_key
        )

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            llm_base_url=os.environ.get(
                "INSIGHTS_LLM_BASE_URL", "http://localhost:11434/v1"
            ).rstrip("/"),
            llm_model=os.environ.get("INSIGHTS_LLM_MODEL", "gemma4:31b-it-q4_K_M"),
            llm_timeout_secs=float(os.environ.get("INSIGHTS_LLM_TIMEOUT_SECS", "400")),
            llm_max_retries=int(os.environ.get("INSIGHTS_LLM_MAX_RETRIES", "2")),
            # Extract defaults to the main (strong) model; verify defaults to a
            # faster model — it does grounding + category only (spoiler is
            # carried from extract, never re-derived by the fast model).
            extract_model=os.environ.get(
                "INSIGHTS_EXTRACT_MODEL",
                os.environ.get("INSIGHTS_LLM_MODEL", "gemma4:31b-it-q4_K_M"),
            ),
            verify_model=os.environ.get("INSIGHTS_VERIFY_MODEL", "qwen3:8b"),
            ondemand_poll_secs=float(os.environ.get("INSIGHTS_ONDEMAND_POLL_SECS", "120")),
            ondemand_max_batch=int(os.environ.get("INSIGHTS_ONDEMAND_MAX_BATCH", "8")),
            scheduled_max_titles=int(os.environ.get("INSIGHTS_SCHEDULED_MAX_TITLES", "200")),
            reseed_interval_secs=float(os.environ.get("INSIGHTS_RESEED_INTERVAL_SECS", "21600")),
            settle_movie_days=int(os.environ.get("INSIGHTS_SETTLE_MOVIE_DAYS", "90")),
            settle_show_days=int(os.environ.get("INSIGHTS_SETTLE_SHOW_DAYS", "60")),
            settle_episode_days=int(os.environ.get("INSIGHTS_SETTLE_EPISODE_DAYS", "30")),
            young_refresh_days=int(os.environ.get("INSIGHTS_YOUNG_REFRESH_DAYS", "14")),
            ttl_movie_days=int(os.environ.get("INSIGHTS_TTL_MOVIE_DAYS", "180")),
            ttl_show_days=int(os.environ.get("INSIGHTS_TTL_SHOW_DAYS", "45")),
            ttl_episode_days=int(os.environ.get("INSIGHTS_TTL_EPISODE_DAYS", "90")),
            data_dir=Path(os.environ.get("INSIGHTS_DATA_DIR", "./data")),
            tmdb_proxy_base_url=os.environ.get(
                "INSIGHTS_TMDB_PROXY_BASE_URL",
                "https://tmdb-proxy.baingurley.workers.dev",
            ).rstrip("/"),
            tmdb_proxy_server_key=os.environ.get("INSIGHTS_TMDB_PROXY_SERVER_KEY", ""),
            library_only=os.environ.get("INSIGHTS_LIBRARY_ONLY", "").lower() in ("1", "true", "yes"),
            plex_base_url=os.environ.get("INSIGHTS_PLEX_BASE_URL", "").rstrip("/"),
            plex_token=os.environ.get("INSIGHTS_PLEX_TOKEN", ""),
            r2_endpoint_url=os.environ.get("INSIGHTS_R2_ENDPOINT_URL", "").rstrip("/"),
            r2_bucket=os.environ.get("INSIGHTS_R2_BUCKET", ""),
            r2_access_key_id=os.environ.get("INSIGHTS_R2_ACCESS_KEY_ID", ""),
            r2_secret_access_key=os.environ.get("INSIGHTS_R2_SECRET_ACCESS_KEY", ""),
        )
