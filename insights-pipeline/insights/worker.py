"""Long-lived worker loop: on-demand requests preempt with absolute priority
every iteration; scheduled work (age-aware TTL refresh -> new episodes ->
popular) is drained one title at a time so a live on-demand request is never
stuck behind a whole scheduled batch.

`ScheduledSource` holds the in-memory scheduled queue: it yields one
`WorkItem` per call, and refills itself via `seed.run()` only once the queue
is empty AND `Config.reseed_interval_secs` has elapsed since the last reseed
-- so the scheduling half (TTL refresh, new-episode pickup, popular seeding)
keeps recurring for the life of the process instead of running once.

`run_forever` is the injectable priority loop (fakes for
`pending_count_fn`/`serve_fn`/`next_scheduled_fn`/`process_one_fn`/
`sleep_fn` let tests drive it without real sleep, R2, TMDB, or GPU calls).
The real entrypoint (`worker_main`) wires these to `serve.run`,
`ScheduledSource.next` + `serve.run_work_items` for the single-title step, an
`R2QueueClient.list_pending` peek, and `time.sleep`, and holds a
non-blocking flock so only one worker instance runs against a given data dir
at a time.
"""

from __future__ import annotations

import fcntl
import logging
import time
from typing import Callable

from insights.config import Config
from insights.r2_queue import Boto3QueueClient
from insights.stages import seed, serve
from insights.stages.seed import WorkItem

logger = logging.getLogger(__name__)


class ScheduledSource:
    """Yields scheduled WorkItems one at a time; refills via `seed_fn` when
    the in-memory queue empties AND the reseed interval has elapsed.
    Injectable `seed_fn` + `monotonic_fn` keep it unit-testable without real
    time or TMDB/Plex calls.
    """

    def __init__(
        self,
        config: Config,
        *,
        seed_fn: Callable[[], list[WorkItem]],
        monotonic_fn: Callable[[], float],
    ) -> None:
        self._config = config
        self._seed_fn = seed_fn
        self._monotonic = monotonic_fn
        self._queue: list[WorkItem] = []
        self._last_seed: float | None = None

    def next(self) -> WorkItem | None:
        if not self._queue:
            now = self._monotonic()
            if (
                self._last_seed is None
                or (now - self._last_seed) >= self._config.reseed_interval_secs
            ):
                self._queue = list(self._seed_fn())
                self._last_seed = now
        return self._queue.pop(0) if self._queue else None


def run_forever(
    *,
    pending_count_fn: Callable[[], int],
    serve_fn: Callable[[], object],
    next_scheduled_fn: Callable[[], WorkItem | None],
    process_one_fn: Callable[[WorkItem], object],
    sleep_fn: Callable[[], None],
) -> None:
    """Priority loop. On-demand preempts EVERY iteration; scheduled work is
    one title per iteration (so a live viewer never waits behind a batch);
    idle sleeps. Ends only when an injected fn raises -- the real
    `sleep_fn` never returns early, so in production this only ends on
    process termination.
    """
    while True:
        if pending_count_fn() > 0:
            serve_fn()
            continue
        item = next_scheduled_fn()
        if item is not None:
            process_one_fn(item)
            continue
        sleep_fn()


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

    try:
        queue = Boto3QueueClient(config)
        source = ScheduledSource(
            config, seed_fn=lambda: seed.run(config), monotonic_fn=time.monotonic
        )
        run_forever(
            pending_count_fn=lambda: len(queue.list_pending(1)),
            serve_fn=lambda: serve.run(config, queue=queue),
            next_scheduled_fn=source.next,
            process_one_fn=lambda item: serve.run_work_items(config, [item]),
            sleep_fn=lambda: time.sleep(config.ondemand_poll_secs),
        )
    finally:
        fcntl.flock(lock_file, fcntl.LOCK_UN)
        lock_file.close()
    return 0
