"""Tests for the worker loop (`insights/worker.py`).

`next_action` is a pure priority decision, tested directly. `run_forever` is
the injectable loop -- driven entirely by fakes here, no real sleep/GPU/R2.
"""

from __future__ import annotations

import pytest

from insights.worker import next_action, run_forever


def test_serve_wins_when_pending():
    assert next_action(pending_count=3, scheduled_remaining=100) == "serve"


def test_scheduled_when_no_pending():
    assert next_action(pending_count=0, scheduled_remaining=5) == "scheduled"


def test_idle_when_nothing():
    assert next_action(pending_count=0, scheduled_remaining=0) == "idle"


def test_run_forever_prioritizes_serve_then_scheduled_then_idle():
    calls = {"serve": 0, "scheduled": 0, "sleep": 0}
    pending_values = iter([2, 0, 0])

    def pending_count_fn():
        return next(pending_values)

    def serve_fn():
        calls["serve"] += 1

    def scheduled_step_fn():
        calls["scheduled"] += 1
        return 0  # nothing left after this bounded pass

    def sleep_fn():
        calls["sleep"] += 1
        raise StopIteration  # ends the loop for the test

    with pytest.raises(StopIteration):
        run_forever(
            config=None,
            serve_fn=serve_fn,
            scheduled_step_fn=scheduled_step_fn,
            pending_count_fn=pending_count_fn,
            sleep_fn=sleep_fn,
        )

    assert calls == {"serve": 1, "scheduled": 1, "sleep": 1}


def test_run_forever_stays_idle_when_nothing_pending_or_scheduled():
    calls = {"serve": 0, "scheduled": 0, "sleep": 0}

    def scheduled_step_fn():
        calls["scheduled"] += 1
        return 0

    def sleep_fn():
        calls["sleep"] += 1
        if calls["sleep"] >= 2:
            raise StopIteration

    with pytest.raises(StopIteration):
        run_forever(
            config=None,
            serve_fn=lambda: calls.__setitem__("serve", calls["serve"] + 1),
            scheduled_step_fn=scheduled_step_fn,
            pending_count_fn=lambda: 0,
            sleep_fn=sleep_fn,
        )

    assert calls["serve"] == 0
    # First tick: scheduled_remaining starts optimistic (>0) so one scheduled
    # attempt happens; it reports 0 remaining, so every tick after is idle.
    assert calls["scheduled"] == 1
    assert calls["sleep"] == 2
