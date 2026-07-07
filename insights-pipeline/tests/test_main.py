"""Tests for the CLI dispatch (`python -m insights <stage>`).

Stage modules' `run()` are monkeypatched so no network/LLM/disk work
actually happens — this only exercises the dispatch logic (arg parsing,
unknown-stage handling, `all` chaining every stage in order).
"""

from __future__ import annotations

import pytest

import insights.__main__ as main_mod
from insights.config import Config


def make_config(tmp_path) -> Config:
    return Config(
        llm_base_url="http://fake/v1",
        llm_model="gemma4:31b-it-q4_K_M",
        llm_timeout_secs=5.0,
        llm_max_retries=1,
        data_dir=tmp_path,
        tmdb_proxy_base_url="https://tmdb-proxy.example",
        plex_base_url="",
        plex_token="",
        r2_endpoint_url="",
        r2_bucket="",
        r2_access_key_id="",
        r2_secret_access_key="",
    )


def test_main_no_args_returns_usage_error(capsys: pytest.CaptureFixture) -> None:
    exit_code = main_mod.main([])
    assert exit_code == 2
    assert "Usage" in capsys.readouterr().err


def test_main_unknown_stage_returns_error(capsys: pytest.CaptureFixture) -> None:
    exit_code = main_mod.main(["bogus-stage"])
    assert exit_code == 2
    assert "Unknown stage" in capsys.readouterr().err


def test_run_stage_dispatches_to_seed(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    from insights.stages import seed

    called = {}
    monkeypatch.setattr(seed, "run", lambda config: called.setdefault("seed", config))

    exit_code = main_mod.run_stage("seed", make_config(tmp_path))
    assert exit_code == 0
    assert "seed" in called


def test_run_stage_dispatches_to_each_named_stage(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    from insights.stages import discover, extract, fetch, publish, seed, verify

    calls: list[str] = []
    monkeypatch.setattr(seed, "run", lambda config: calls.append("seed"))
    monkeypatch.setattr(discover, "run", lambda config: calls.append("discover"))
    monkeypatch.setattr(fetch, "run", lambda config: calls.append("fetch"))
    monkeypatch.setattr(extract, "run", lambda config, *a: calls.append("extract"))
    monkeypatch.setattr(verify, "run", lambda config, *a: calls.append("verify"))
    monkeypatch.setattr(publish, "run", lambda config, **kw: calls.append("publish"))

    config = make_config(tmp_path)
    for stage in ("seed", "discover", "fetch", "extract", "verify", "publish"):
        calls.clear()
        assert main_mod.run_stage(stage, config) == 0
        assert calls == [stage]


def test_run_all_chains_every_stage_in_order(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    from insights.stages import discover, extract, fetch, publish, seed, verify

    calls: list[str] = []
    monkeypatch.setattr(seed, "run", lambda config: calls.append("seed"))
    monkeypatch.setattr(discover, "run", lambda config: calls.append("discover"))
    monkeypatch.setattr(fetch, "run", lambda config: calls.append("fetch") or {"k": []})
    monkeypatch.setattr(
        extract, "run", lambda config, pages: calls.append("extract") or {"k": []}
    )
    monkeypatch.setattr(verify, "run", lambda config, facts: calls.append("verify"))
    monkeypatch.setattr(publish, "run", lambda config: calls.append("publish") or [])

    exit_code = main_mod.run_all(make_config(tmp_path))

    assert exit_code == 0
    assert calls == ["seed", "discover", "fetch", "extract", "verify", "publish"]


def test_run_stage_all_delegates_to_run_all(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    called = {}

    def fake_run_all(config):
        called["ran"] = True
        return 0

    monkeypatch.setattr(main_mod, "run_all", fake_run_all)
    exit_code = main_mod.run_stage("all", make_config(tmp_path))
    assert exit_code == 0
    assert called.get("ran") is True


def test_main_configures_logging_and_dispatches(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    called = {}

    def fake_configure_logging():
        called["logging"] = True

    def fake_run_stage(stage, config):
        called["stage"] = stage
        return 0

    monkeypatch.setattr(main_mod, "_configure_logging", fake_configure_logging)
    monkeypatch.setattr(main_mod.Config, "from_env", classmethod(lambda cls: make_config(tmp_path)))
    monkeypatch.setattr(main_mod, "run_stage", fake_run_stage)

    exit_code = main_mod.main(["seed"])

    assert exit_code == 0
    assert called["logging"] is True
    assert called["stage"] == "seed"
