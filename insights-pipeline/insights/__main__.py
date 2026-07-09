"""CLI dispatch: `python -m insights <stage> [args]` — the Dockerfile entrypoint.

Each stage is idempotent and resumable (reads its input from the prior
stage's on-disk output in `Config.data_dir`, writes its own on-disk output,
skips already-processed keys on re-run — see each stage module's `run()`).
Running `all` chains every stage in-process for a one-shot batch, passing
each stage's return value straight to the next rather than round-tripping
through disk for the parts of a single invocation that don't need to.

Usage:
    python -m insights seed
    python -m insights discover
    python -m insights fetch
    python -m insights extract
    python -m insights verify
    python -m insights publish
    python -m insights all
    python -m insights serve
    python -m insights worker
"""

from __future__ import annotations

import logging
import sys

from insights.config import Config

STAGE_NAMES = (
    "seed",
    "discover",
    "fetch",
    "extract",
    "verify",
    "publish",
    "all",
    "serve",
    "worker",
)


def _configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def run_stage(stage: str, config: Config) -> int:
    if stage == "seed":
        from insights.stages import seed

        seed.run(config)
    elif stage == "discover":
        from insights.stages import discover

        discover.run(config)
    elif stage == "fetch":
        from insights.stages import fetch

        fetch.run(config)
    elif stage == "extract":
        from insights.stages import extract

        extract.run(config)
    elif stage == "verify":
        from insights.stages import verify

        verify.run(config)
    elif stage == "publish":
        from insights.stages import publish

        publish.run(config)
    elif stage == "all":
        return run_all(config)
    elif stage == "serve":
        from insights.stages import serve

        served = serve.run(config)
        logging.getLogger("insights.serve").info("serve: drained %d request(s)", len(served))
    elif stage == "worker":
        from insights.worker import worker_main

        return worker_main(config)
    else:
        print(f"Unknown stage: {stage!r}. Choose from: {', '.join(STAGE_NAMES)}", file=sys.stderr)
        return 2
    return 0


def run_all(config: Config) -> int:
    """Chain every stage in-process for a one-shot batch run.

    Passes each stage's in-memory return value to the next (skipping the
    disk round-trip within this single invocation) — each stage still
    writes its own on-disk output as it goes, so a later standalone
    `python -m insights <stage>` run resumes from exactly where this left
    off, or from a partial `all` run that was interrupted.
    """
    from insights.stages import discover, extract, fetch, publish, seed, verify

    logger = logging.getLogger("insights.all")

    seed.run(config)
    discover.run(config)
    pages_by_key = fetch.run(config)
    facts_by_key = extract.run(config, pages_by_key)
    verify.run(config, facts_by_key)
    plans = publish.run(config)

    logger.info("all: published %d titles", len(plans))
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    if not argv:
        print(f"Usage: python -m insights <stage> [args]\nStages: {', '.join(STAGE_NAMES)}", file=sys.stderr)
        return 2

    stage = argv[0]
    if stage not in STAGE_NAMES:
        print(f"Unknown stage: {stage!r}. Choose from: {', '.join(STAGE_NAMES)}", file=sys.stderr)
        return 2

    _configure_logging()
    config = Config.from_env()
    return run_stage(stage, config)


if __name__ == "__main__":
    raise SystemExit(main())
