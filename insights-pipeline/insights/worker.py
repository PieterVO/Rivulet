"""Long-lived worker loop: drain the on-demand queue first, else make one
bounded scheduled pass (age-aware TTL refresh -> new episodes -> popular),
re-checking the on-demand queue between passes so a fresh on-demand request
never waits behind a long scheduled batch.

Pure core: `next_action` is the priority decision. `run_forever` is the
injectable loop (fakes for `serve_fn`/`scheduled_step_fn`/`pending_count_fn`/
`sleep_fn` let tests drive it without real sleep, R2, or GPU calls). The real
entrypoint (`worker_main`) wires these to `serve.run`, one bounded scheduled
chunk, an `R2QueueClient.list_pending` peek, and `time.sleep`, and holds a
non-blocking flock so only one worker instance runs against a given data dir
at a time.
"""

from __future__ import annotations

import fcntl
import logging
import time
from typing import Callable, Literal

from insights.config import Config
from insights.r2_queue import Boto3QueueClient
from insights.stages import discover, extract, fetch, publish, seed, serve, verify

logger = logging.getLogger(__name__)

Action = Literal["serve", "scheduled", "idle"]


def next_action(pending_count: int, scheduled_remaining: int) -> Action:
    """Pure: on-demand requests always win; otherwise scheduled work if any
    remains; otherwise idle (nothing to do until the next poll).
    """
    if pending_count > 0:
        return "serve"
    if scheduled_remaining > 0:
        return "scheduled"
    return "idle"


def run_forever(
    config: Config | None,
    *,
    serve_fn: Callable[[], object],
    scheduled_step_fn: Callable[[], int],
    pending_count_fn: Callable[[], int],
    sleep_fn: Callable[[], None],
) -> None:
    """Injectable priority loop. Runs until `sleep_fn` (or any injected fn)
    raises to stop it -- the real entrypoint's `sleep_fn` never returns
    early, so in production this only ends on process termination.

    `scheduled_remaining` starts optimistic (assume there is at least one
    scheduled title to try) so the very first idle-priority tick still
    attempts a scheduled pass; `scheduled_step_fn`'s return value (titles
    remaining after that bounded pass) then drives subsequent ticks honestly.
    """
    scheduled_remaining = 1
    while True:
        pending = pending_count_fn()
        action = next_action(pending_count=pending, scheduled_remaining=scheduled_remaining)
        if action == "serve":
            serve_fn()
        elif action == "scheduled":
            scheduled_remaining = scheduled_step_fn()
        else:
            sleep_fn()


def _scheduled_step(config: Config) -> int:
    """One bounded scheduled pass: re-seed (age-aware TTL refresh -> new
    episodes -> popular, capped at `scheduled_max_titles`) and run it
    through the full discover->publish chain.

    Returns 0 always -- each pass re-seeds from scratch next tick (freshness
    is re-evaluated against the clock at that time), so there is no
    persistent "remaining" count to track across ticks beyond "try again."
    """
    work_items = seed.run(config)
    discover.run(config)
    pages_by_key = fetch.run(config)
    facts_by_key = extract.run(config, pages_by_key)
    verify.run(config, facts_by_key)
    plans = publish.run(config)
    logger.info(
        "worker: scheduled pass seeded %d, published %d", len(work_items), len(plans)
    )
    return 0


def worker_main(config: Config) -> int:
    """Real entrypoint: acquire a non-blocking flock (one worker per data
    dir), then run the priority loop forever.
    """
    config.data_dir.mkdir(parents=True, exist_ok=True)
    lock_path = config.data_dir / "worker.lock"
    lock_file = lock_path.open("w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        logger.error("worker: another instance already holds %s; exiting", lock_path)
        lock_file.close()
        return 1

    queue = Boto3QueueClient(config)
    try:
        run_forever(
            config,
            serve_fn=lambda: serve.run(config, queue=queue),
            scheduled_step_fn=lambda: _scheduled_step(config),
            pending_count_fn=lambda: len(queue.list_pending(1)),
            sleep_fn=lambda: time.sleep(config.ondemand_poll_secs),
        )
    finally:
        fcntl.flock(lock_file, fcntl.LOCK_UN)
        lock_file.close()
    return 0
