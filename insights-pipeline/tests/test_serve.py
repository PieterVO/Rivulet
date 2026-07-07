"""Tests for the on-demand `serve` stage (`insights/stages/serve.py`).

`queue_to_work_items` is a pure mapper, tested directly. `run()` is tested
against a fake queue + monkeypatched stage `run()`s -- no real R2, LLM, or
network calls.
"""

from __future__ import annotations

from insights.stages.serve import queue_to_work_items
from tests.helpers import make_config


def test_maps_requests_and_drops_published():
    reqs = [
        {
            "key": "tv:125988:S1E1",
            "type": "tv",
            "tmdb_id": 125988,
            "season": 1,
            "episode": 1,
            "title": "Silo",
            "year": 2023,
        },
        {"key": "movie:27205", "type": "movie", "tmdb_id": 27205, "title": "Inception", "year": 2010},
    ]
    out = queue_to_work_items(reqs, published_keys={"movie:27205"})
    assert [w.key for w in out] == ["tv:125988:S1E1"]
    assert out[0].season == 1 and out[0].episode == 1


class _FakeQueue:
    def __init__(self, pending_keys, requests_by_key):
        self._pending_keys = pending_keys
        self._requests_by_key = requests_by_key
        self.deleted: list[str] = []
        self.list_pending_calls: list[int] = []

    def list_pending(self, max_items):
        self.list_pending_calls.append(max_items)
        return self._pending_keys[:max_items]

    def get_request(self, work_item_key):
        return self._requests_by_key.get(work_item_key)

    def delete_request(self, work_item_key):
        self.deleted.append(work_item_key)

    def object_exists(self, published_key):
        return False


def test_run_drains_queue_through_pipeline_and_deletes_served(tmp_path, monkeypatch):
    config = make_config(data_dir=tmp_path)

    pending = {
        "movie:1": {"key": "movie:1", "type": "movie", "tmdb_id": 1, "title": "A", "year": 2020},
        "movie:2": {"key": "movie:2", "type": "movie", "tmdb_id": 2, "title": "B", "year": 2021},
    }
    queue = _FakeQueue(list(pending.keys()), pending)

    calls: list[str] = []

    import insights.stages.serve as serve_mod

    monkeypatch.setattr(serve_mod.discover, "run", lambda cfg: calls.append("discover") or [])
    monkeypatch.setattr(serve_mod.fetch, "run", lambda cfg: calls.append("fetch") or {})
    monkeypatch.setattr(serve_mod.extract, "run", lambda cfg, pages: calls.append("extract") or {})
    monkeypatch.setattr(serve_mod.verify, "run", lambda cfg, facts: calls.append("verify") or [])
    monkeypatch.setattr(serve_mod.publish, "run", lambda cfg: calls.append("publish") or [])

    served = serve_mod.run(config, queue=queue)

    assert set(served) == {"movie:1", "movie:2"}
    assert calls == ["discover", "fetch", "extract", "verify", "publish"]
    assert set(queue.deleted) == {"movie:1", "movie:2"}


def test_run_returns_empty_immediately_when_queue_empty(tmp_path, monkeypatch):
    config = make_config(data_dir=tmp_path)
    queue = _FakeQueue([], {})

    import insights.stages.serve as serve_mod

    called = []
    monkeypatch.setattr(serve_mod.discover, "run", lambda cfg: called.append("discover"))

    served = serve_mod.run(config, queue=queue)

    assert served == []
    assert called == []  # no LLM/pipeline work when nothing is pending


def test_run_bounds_batch_to_ondemand_max_batch(tmp_path, monkeypatch):
    config = make_config(data_dir=tmp_path, ondemand_max_batch=8)

    pending = {
        f"movie:{i}": {"key": f"movie:{i}", "type": "movie", "tmdb_id": i, "title": str(i), "year": 2020}
        for i in range(20)
    }
    queue = _FakeQueue(list(pending.keys()), pending)

    import insights.stages.serve as serve_mod

    monkeypatch.setattr(serve_mod.discover, "run", lambda cfg: [])
    monkeypatch.setattr(serve_mod.fetch, "run", lambda cfg: {})
    monkeypatch.setattr(serve_mod.extract, "run", lambda cfg, pages: {})
    monkeypatch.setattr(serve_mod.verify, "run", lambda cfg, facts: [])
    monkeypatch.setattr(serve_mod.publish, "run", lambda cfg: [])

    served = serve_mod.run(config, queue=queue)

    assert len(served) <= 8
    assert queue.list_pending_calls == [8]
