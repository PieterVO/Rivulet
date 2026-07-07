"""Pipeline configuration — all runtime settings from env, never hardcoded.

The pipeline is model-agnostic via an OpenAI-compatible endpoint (Ollama by
default). R2 credentials and the Plex library-dump access come from env too.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

PIPELINE_VERSION = 1


@dataclass(frozen=True, slots=True)
class Config:
    # LLM (OpenAI-compatible; Ollama default). The bake-off picks the model.
    llm_base_url: str
    llm_model: str
    llm_timeout_secs: float
    llm_max_retries: int

    # Where each stage reads/writes its on-disk output.
    data_dir: Path

    # TMDB access is via the existing tmdb-proxy Worker (don't re-implement).
    tmdb_proxy_base_url: str

    # Plex library dump (same box as the pipeline in prod).
    plex_base_url: str
    plex_token: str

    # R2 (S3-compatible). Empty until the user enables R2; publish stage
    # checks for these and errors clearly if unset.
    r2_endpoint_url: str
    r2_bucket: str
    r2_access_key_id: str
    r2_secret_access_key: str

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
            llm_model=os.environ.get("INSIGHTS_LLM_MODEL", "qwen2.5:32b-instruct"),
            llm_timeout_secs=float(os.environ.get("INSIGHTS_LLM_TIMEOUT_SECS", "400")),
            llm_max_retries=int(os.environ.get("INSIGHTS_LLM_MAX_RETRIES", "2")),
            data_dir=Path(os.environ.get("INSIGHTS_DATA_DIR", "./data")),
            tmdb_proxy_base_url=os.environ.get(
                "INSIGHTS_TMDB_PROXY_BASE_URL",
                "https://tmdb-proxy.baingurley.workers.dev",
            ).rstrip("/"),
            plex_base_url=os.environ.get("INSIGHTS_PLEX_BASE_URL", "").rstrip("/"),
            plex_token=os.environ.get("INSIGHTS_PLEX_TOKEN", ""),
            r2_endpoint_url=os.environ.get("INSIGHTS_R2_ENDPOINT_URL", "").rstrip("/"),
            r2_bucket=os.environ.get("INSIGHTS_R2_BUCKET", ""),
            r2_access_key_id=os.environ.get("INSIGHTS_R2_ACCESS_KEY_ID", ""),
            r2_secret_access_key=os.environ.get("INSIGHTS_R2_SECRET_ACCESS_KEY", ""),
        )
