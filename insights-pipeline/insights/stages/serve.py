"""Stage: serve — drain the on-demand request queue through the pipeline.

The app POSTs a generation request to the public Worker on a 404, which
writes one R2 object per request under `requests/pending/` (see
`insights.r2_queue`). This stage is the fast, single-title-batch path: list
pending requests (bounded by `Config.ondemand_max_batch` so one drain can't
runaway the GPU queue), map them to `WorkItem`s (dropping anything already
published -- the Worker itself also checks this on request, but a request
can still race a publish that landed in between), write them as this run's
seed, then run the existing discover->publish chain on just those items.

Every served request is deleted from the queue once the pipeline has run for
it, whether the outcome was a covered publish or a tombstone -- a tombstone
IS an answer ("nothing to share"), not a failure to retry.
"""

from __future__ import annotations

import logging

from insights.config import Config
from insights.r2_queue import Boto3QueueClient, R2QueueClient
from insights.stages import discover, extract, fetch, publish, verify
from insights.stages.seed import WorkItem, load_published_keys, write_seed_jsonl

logger = logging.getLogger(__name__)


def queue_to_work_items(requests: list[dict], published_keys: set[str]) -> list[WorkItem]:
    """Pure: queue request dicts -> WorkItems, dropping already-published keys.

    Request dicts are the snake_case queue object shape the Worker writes
    (see the shared contract): `key`, `type`, `tmdb_id`, optional
    `season`/`episode`, `title`, `year`. A malformed request (missing/
    unusable `tmdb_id` or `type`) is skipped and logged rather than raising
    -- `run()` below still deletes it from the queue so one bad object can't
    wedge the on-demand drain for everything behind it.
    """
    out: list[WorkItem] = []
    for req in requests:
        key = req.get("key")
        if key in published_keys:
            continue
        try:
            out.append(
                WorkItem(
                    tmdb_id=int(req["tmdb_id"]),
                    type=req["type"],
                    title=req.get("title", ""),
                    year=req.get("year"),
                    season=req.get("season"),
                    episode=req.get("episode"),
                    reason="ondemand",
                )
            )
        except (KeyError, TypeError, ValueError) as exc:
            logger.warning("serve: dropping malformed request %r: %s", key, exc)
            continue
    return out


def run_work_items(config: Config, work_items: list[WorkItem]) -> list[str]:
    """Write `work_items` as this run's seed and run discover->publish on just
    them, returning the served `WorkItem.key` strings.

    Shared single-batch core: the on-demand drain (`run`, below) calls this
    with a bounded batch of queued requests; the scheduled worker's
    `ScheduledSource` (see `insights.worker`) calls this with exactly one
    title per loop iteration, so a live on-demand request is never stuck
    behind a whole scheduled batch. Returns `[]` immediately -- no LLM call --
    when there is nothing to do.
    """
    if not work_items:
        return []
    write_seed_jsonl(work_items, config.data_dir / "seed.jsonl")
    discover.run(config)
    pages_by_key = fetch.run(config)
    facts_by_key = extract.run(config, pages_by_key)
    verify.run(config, facts_by_key)
    publish.run(config)
    return [w.key for w in work_items]


def run(config: Config, queue: R2QueueClient | None = None) -> list[str]:
    """IO shell: drain up to `ondemand_max_batch` pending requests through the pipeline.

    Returns the served work-item keys (deleted from the queue). Returns `[]`
    immediately -- no LLM call, no error -- when the queue is empty.
    """
    queue = queue or Boto3QueueClient(config)
    keys = queue.list_pending(config.ondemand_max_batch)
    if not keys:
        return []

    requests = [r for k in keys if (r := _safe_get_request(queue, k)) is not None]
    published_keys = load_published_keys(config.data_dir / "published.jsonl")
    work_items = queue_to_work_items(requests, published_keys)

    run_work_items(config, work_items)

    # Every listed key is deleted regardless of outcome -- covered publish,
    # tombstone, already-published no-op, or an unreadable/malformed poison
    # object (isolated above): each is "answered" and must not wedge the
    # on-demand queue for the next drain.
    for key in keys:
        queue.delete_request(key)

    logger.info("serve: drained %d on-demand request(s)", len(keys))
    return keys


def _safe_get_request(queue: R2QueueClient, key: str) -> dict | None:
    """Read one queue request, isolating a corrupt/unreadable object so it
    can't abort the whole batch before the delete loop runs (see `run`).
    """
    try:
        return queue.get_request(key)
    except Exception as exc:  # any read/parse failure is poison, not fatal
        logger.warning("serve: dropping unreadable request %r: %s", key, exc)
        return None
