"""Tests for the worker loop (`insights/worker.py`).

`run_forever` is the injectable priority loop -- driven entirely by fakes
here, no real sleep/GPU/R2. On-demand preempts every iteration; scheduled
work is yielded one title at a time by `ScheduledSource`, which is tested
separately below with a fake clock and a fake `seed_fn`.
"""

from __future__ import annotations

import pytest

from insights.worker import ScheduledSource, run_forever
from tests.helpers import make_config


def test_serve_preempts_scheduled():
    calls = {"serve": 0, "scheduled": 0, "sleep": 0}
    pending_values = iter([1, 1, 0, 0])

    def pending_count_fn():
        return next(pending_values)

    def serve_fn():
        calls["serve"] += 1

    def next_scheduled_fn():
        calls["scheduled"] += 1
        return None

    def process_one_fn(item):
        raise AssertionError("should not be called while pending > 0")

    def sleep_fn():
        calls["sleep"] += 1
        raise StopIteration

    with pytest.raises(StopIteration):
        run_forever(
            pending_count_fn=pending_count_fn,
            serve_fn=serve_fn,
            next_scheduled_fn=next_scheduled_fn,
            process_one_fn=process_one_fn,
            sleep_fn=sleep_fn,
        )

    # First two ticks: pending > 0 -> serve only, no scheduled check at all.
    # Third tick: pending == 0 -> checks scheduled (gets None) -> sleeps, which
    # raises to end the test on the fourth tick's pending() call never happening.
    assert calls["serve"] == 2
    assert calls["scheduled"] == 1
    assert calls["sleep"] == 1


def test_processes_scheduled_one_at_a_time():
    calls = {"serve": 0, "sleep": 0}
    processed: list[str] = []
    scheduled_values = iter(["itemA", "itemB", None])

    def next_scheduled_fn():
        return next(scheduled_values)

    def process_one_fn(item):
        processed.append(item)

    def sleep_fn():
        calls["sleep"] += 1
        raise StopIteration

    with pytest.raises(StopIteration):
        run_forever(
            pending_count_fn=lambda: 0,
            serve_fn=lambda: calls.__setitem__("serve", calls["serve"] + 1),
            next_scheduled_fn=next_scheduled_fn,
            process_one_fn=process_one_fn,
            sleep_fn=sleep_fn,
        )

    assert processed == ["itemA", "itemB"]
    assert calls["serve"] == 0
    assert calls["sleep"] == 1


def test_idle_sleeps_when_nothing():
    calls = {"sleep": 0}

    def sleep_fn():
        calls["sleep"] += 1
        raise StopIteration

    with pytest.raises(StopIteration):
        run_forever(
            pending_count_fn=lambda: 0,
            serve_fn=lambda: (_ for _ in ()).throw(AssertionError("no serve")),
            next_scheduled_fn=lambda: None,
            process_one_fn=lambda item: (_ for _ in ()).throw(AssertionError("no process")),
            sleep_fn=sleep_fn,
        )

    assert calls["sleep"] == 1


# --- ScheduledSource: refills via seed_fn on a time cadence ---


def test_scheduled_source_first_call_seeds():
    config = make_config(reseed_interval_secs=100.0)
    seed_calls = {"n": 0}

    def seed_fn():
        seed_calls["n"] += 1
        return ["X"]

    clock = {"t": 0.0}
    source = ScheduledSource(config, seed_fn=seed_fn, monotonic_fn=lambda: clock["t"])

    assert source.next() == "X"
    assert seed_calls["n"] == 1


def test_scheduled_source_recurs_after_cadence():
    config = make_config(reseed_interval_secs=100.0)
    seed_calls = {"n": 0}

    def seed_fn():
        seed_calls["n"] += 1
        return ["X"]

    clock = {"t": 0.0}
    source = ScheduledSource(config, seed_fn=seed_fn, monotonic_fn=lambda: clock["t"])

    # First call: queue empty, never seeded -> seeds immediately, returns X.
    assert source.next() == "X"
    assert seed_calls["n"] == 1

    # Queue now empty again; cadence has NOT elapsed -> no reseed, returns None.
    clock["t"] = 50.0
    assert source.next() is None
    assert seed_calls["n"] == 1

    # Cadence elapsed -> reseeds and returns X again.
    clock["t"] = 101.0
    assert source.next() == "X"
    assert seed_calls["n"] == 2
