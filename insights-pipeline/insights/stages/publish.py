"""Stage 6: publish — assemble published TitleTrivia JSON, key it, upload to R2.

Reads `facts_verified.jsonl` grouped by work item, assembles the published
`TitleTrivia` payload per `models.py` (source_snippet stripped via
`Fact.to_published_dict()` — the schema is locked to the Swift client, this
stage does not touch it), derives the R2 object key, and uploads.

R2 upload — the wrangler `--remote` gotcha: `wrangler r2 object put`
WITHOUT `--remote` writes to wrangler's local Miniflare simulator, not the
real bucket; the deployed Worker (`insights-api.baingurley.workers.dev`)
would see nothing. This stage shells out to
`wrangler r2 object put <bucket>/<key> --file <path> --remote`
(wrangler is already OAuth-authed on the box — no R2 API token needed,
which is why this is preferred over the boto3 S3-compatible path). A
boto3 path is also implemented, gated behind `config.r2_configured`, for
if/when an R2 API token exists — but wrangler is the default/preferred
uploader per the plan.

Pure core: `derive_object_key` (movie/episode key derivation) and
`assemble_title_trivia` (facts -> TitleTrivia, attribution dedup) are unit
tested directly, no IO. The uploader is a small `Uploader` protocol so
`run()`'s upload calls are shelled/mocked in tests — no real `wrangler`
invocation or R2 credentials required to test payload assembly + key
derivation, per the task instructions.
"""

from __future__ import annotations

import json
import logging
import subprocess
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Protocol

from insights.config import PIPELINE_VERSION, Config
from insights.models import Fact, Source, TitleTrivia
from insights.stages.seed import WorkItem

logger = logging.getLogger(__name__)


class PublishError(RuntimeError):
    """Raised when an R2 upload fails."""


class Uploader(Protocol):
    def upload(self, local_path: Path, key: str) -> None:
        """Upload the file at `local_path` to the R2 bucket under `key`."""
        ...


def derive_object_key(work_item: WorkItem) -> str:
    """Pure: `insights/movie/{id}.json` or `insights/tv/{id}/{s}/{e}.json`.

    Matches the spec's fact-store key scheme exactly (`## Fact store
    schema` in the design doc uses `insights/movie/{id}.json` for movies;
    TV keys are per-episode: `insights/tv/{tmdbId}/{season}/{episode}.json`
    — the show's own tmdb id, not the episode's).
    """
    if work_item.type == "movie":
        return f"insights/movie/{work_item.tmdb_id}.json"
    if work_item.season is None or work_item.episode is None:
        raise ValueError(
            f"TV work item {work_item.key} is missing season/episode; "
            "publish only supports per-episode TV trivia, not show-level."
        )
    return f"insights/tv/{work_item.tmdb_id}/{work_item.season}/{work_item.episode}.json"


def _title_trivia_id(work_item: WorkItem) -> str:
    """`id` field inside the published payload, e.g. "tmdb://27205"."""
    return f"tmdb://{work_item.tmdb_id}"


def _title_trivia_type(work_item: WorkItem) -> str:
    if work_item.type == "movie":
        return "movie"
    return "episode" if work_item.season is not None else "show"


def dedup_attribution(sources: list[Source]) -> list[Source]:
    """Pure: attribution list with duplicate (name, url) sources collapsed,
    original order preserved (first occurrence wins).
    """
    seen: set[tuple[str, str]] = set()
    result: list[Source] = []
    for source in sources:
        key = (source.name, source.url)
        if key in seen:
            continue
        seen.add(key)
        result.append(source)
    return result


def assemble_title_trivia(work_item: WorkItem, facts: list[Fact], generated_at: str) -> TitleTrivia:
    """Pure: build the published TitleTrivia for one work item's verified facts.

    Attribution is derived from the facts' own sources (deduped) rather
    than passed separately — every fact already carries the attribution it
    needs, so there is only one source of truth for "what got attributed."
    """
    attribution = dedup_attribution([fact.source for fact in facts])
    return TitleTrivia(
        id=_title_trivia_id(work_item),
        type=_title_trivia_type(work_item),  # type: ignore[arg-type]
        generated_at=generated_at,
        pipeline_version=PIPELINE_VERSION,
        attribution=attribution,
        facts=facts,
    )


@dataclass(slots=True, frozen=True)
class PublishPlan:
    """What `run()` will write/upload for one work item — the pure output
    of assembly, before any IO happens. Makes the upload step in tests a
    matter of asserting against this plan rather than a real file/network.
    """

    key: str
    work_item_key: str
    payload: dict[str, object]


def build_publish_plan(work_item: WorkItem, facts: list[Fact], generated_at: str) -> PublishPlan:
    """Pure: work item + verified facts -> the R2 key + published JSON payload."""
    trivia = assemble_title_trivia(work_item, facts, generated_at)
    return PublishPlan(
        key=derive_object_key(work_item),
        work_item_key=work_item.key,
        payload=trivia.to_published_dict(),
    )


class WranglerUploader:
    """Shells out to `wrangler r2 object put <bucket>/<key> --file <path> --remote`.

    Preferred uploader: wrangler is already OAuth-authed on the box, so no
    R2 API token/secret is needed. CRITICAL: omitting `--remote` silently
    writes to wrangler's local Miniflare simulator instead of the real
    bucket — always pass it.
    """

    def __init__(self, bucket: str, wrangler_cwd: Path | None = None) -> None:
        self.bucket = bucket
        self.wrangler_cwd = wrangler_cwd

    def upload(self, local_path: Path, key: str) -> None:
        cmd = [
            "wrangler",
            "r2",
            "object",
            "put",
            f"{self.bucket}/{key}",
            "--file",
            str(local_path),
            "--content-type",
            "application/json",
            "--remote",
        ]
        result = subprocess.run(cmd, cwd=self.wrangler_cwd, capture_output=True, text=True)
        if result.returncode != 0:
            raise PublishError(
                f"wrangler r2 object put failed for {key}: {result.stderr.strip()}"
            )
        logger.info("publish: uploaded %s via wrangler --remote", key)


class Boto3Uploader:
    """S3-compatible upload via boto3, gated behind `config.r2_configured`.

    Fallback path for once an R2 API token exists; not the default (see
    module docstring — wrangler needs no token and is simpler today).
    """

    def __init__(self, config: Config) -> None:
        if not config.r2_configured:
            raise PublishError(
                "Boto3Uploader requires INSIGHTS_R2_ENDPOINT_URL/BUCKET/ACCESS_KEY_ID/"
                "SECRET_ACCESS_KEY to be set; use WranglerUploader instead."
            )
        self.config = config

    def upload(self, local_path: Path, key: str) -> None:
        import boto3

        client = boto3.client(
            "s3",
            endpoint_url=self.config.r2_endpoint_url,
            aws_access_key_id=self.config.r2_access_key_id,
            aws_secret_access_key=self.config.r2_secret_access_key,
        )
        try:
            client.upload_file(str(local_path), self.config.r2_bucket, key)
        except Exception as exc:  # noqa: BLE001 - surface any boto3 failure uniformly
            raise PublishError(f"boto3 upload failed for {key}: {exc}") from exc
        logger.info("publish: uploaded %s via boto3", key)


def load_facts_verified_grouped(path: Path) -> dict[str, list[Fact]]:
    """Read facts_verified.jsonl keyed by WorkItem.key (reuses the same shape verify writes)."""
    from insights.stages.verify import load_facts_verified_jsonl

    return load_facts_verified_jsonl(path)


def load_seed_index(path: Path) -> dict[str, WorkItem]:
    from insights.stages.seed import load_seed_jsonl

    return {item.key: item for item in load_seed_jsonl(path)}


DEFAULT_R2_BUCKET = "rivulet-insights"


def run(config: Config, *, uploader: Uploader | None = None, generated_at: str | None = None) -> list[PublishPlan]:
    """IO shell: assemble + write local JSON + upload every verified work item to R2.

    `uploader` defaults to WranglerUploader(config.r2_bucket, falling back
    to the real bucket name if `INSIGHTS_R2_BUCKET` is unset — wrangler
    needs only the bucket name, not the full S3-style credential set
    `Config.r2_configured` gates, since it authenticates via its own OAuth
    session) — pass a fake in tests. `generated_at` defaults to now (UTC,
    ISO8601); pass a fixed value in tests for determinism.
    """
    generated_at = generated_at or datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    facts_by_key = load_facts_verified_grouped(config.data_dir / "facts_verified.jsonl")
    work_items_by_key = load_seed_index(config.data_dir / "seed.jsonl")

    bucket = config.r2_bucket or DEFAULT_R2_BUCKET
    active_uploader: Uploader = uploader or WranglerUploader(bucket=bucket)

    publish_dir = config.data_dir / "published"
    publish_dir.mkdir(parents=True, exist_ok=True)

    plans: list[PublishPlan] = []
    skipped = 0
    for key, facts in facts_by_key.items():
        work_item = work_items_by_key.get(key)
        if work_item is None:
            logger.warning("publish: %s has verified facts but no matching seed entry; skipping", key)
            skipped += 1
            continue
        if not facts:
            logger.info("publish: %s has zero verified facts; skipping (no trivia to publish)", key)
            skipped += 1
            continue

        plan = build_publish_plan(work_item, facts, generated_at)
        local_path = publish_dir / plan.key.replace("/", "__")
        local_path.write_text(json.dumps(plan.payload, indent=2), encoding="utf-8")

        active_uploader.upload(local_path, plan.key)
        plans.append(plan)

    logger.info("publish: %d work items published, %d skipped", len(plans), skipped)
    return plans
