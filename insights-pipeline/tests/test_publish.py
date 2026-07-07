"""Tests for the publish stage: key derivation, payload assembly, and the
upload path (shelled/mocked — no real wrangler invocation, no R2 creds).
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from insights.models import Fact, Source
from insights.stages.publish import (
    PublishError,
    WranglerUploader,
    assemble_title_trivia,
    build_publish_plan,
    dedup_attribution,
    derive_object_key,
    load_facts_verified_grouped,
    load_seed_index,
    run,
)
from insights.stages.seed import WorkItem, write_seed_jsonl
from insights.stages.verify import VerifyBatchResult, write_facts_verified_jsonl

WIKI = Source(name="Wikipedia", url="https://en.wikipedia.org/wiki/Inception")
FANDOM = Source(name="Silo Wiki", url="https://silo.fandom.com/wiki/Silo")


def make_fact(text: str, source: Source = WIKI, category: str = "production", spoiler: int = 0) -> Fact:
    return Fact(text=text, category=category, spoiler=spoiler, source=source, source_snippet=text)


# --- derive_object_key ---


def test_derive_object_key_movie() -> None:
    item = WorkItem(tmdb_id=27205, type="movie", title="Inception", year=2010)
    assert derive_object_key(item) == "insights/movie/27205.json"


def test_derive_object_key_episode() -> None:
    item = WorkItem(tmdb_id=2802, type="tv", title="Silo", year=2023, season=1, episode=3)
    assert derive_object_key(item) == "insights/tv/2802/1/3.json"


def test_derive_object_key_show_level_tv_raises() -> None:
    item = WorkItem(tmdb_id=2802, type="tv", title="Silo", year=2023)  # no season/episode
    with pytest.raises(ValueError, match="season/episode"):
        derive_object_key(item)


# --- dedup_attribution ---


def test_dedup_attribution_removes_exact_duplicates_preserves_order() -> None:
    sources = [WIKI, FANDOM, WIKI, FANDOM]
    assert dedup_attribution(sources) == [WIKI, FANDOM]


def test_dedup_attribution_empty() -> None:
    assert dedup_attribution([]) == []


# --- assemble_title_trivia ---


def test_assemble_title_trivia_movie_shape() -> None:
    item = WorkItem(tmdb_id=27205, type="movie", title="Inception", year=2010)
    facts = [make_fact("Fact one.", WIKI), make_fact("Fact two.", FANDOM)]

    trivia = assemble_title_trivia(item, facts, generated_at="2026-07-07T00:00:00Z")

    assert trivia.id == "tmdb://27205"
    assert trivia.type == "movie"
    assert trivia.generated_at == "2026-07-07T00:00:00Z"
    assert trivia.pipeline_version == 1
    assert trivia.attribution == [WIKI, FANDOM]
    assert trivia.facts == facts


def test_assemble_title_trivia_episode_type() -> None:
    item = WorkItem(tmdb_id=2802, type="tv", title="Silo", year=2023, season=1, episode=1)
    trivia = assemble_title_trivia(item, [make_fact("A fact.")], generated_at="2026-01-01T00:00:00Z")
    assert trivia.type == "episode"


def test_assemble_title_trivia_show_level_type() -> None:
    item = WorkItem(tmdb_id=2802, type="tv", title="Silo", year=2023)
    trivia = assemble_title_trivia(item, [make_fact("A fact.")], generated_at="2026-01-01T00:00:00Z")
    assert trivia.type == "show"


def test_assemble_title_trivia_attribution_dedups_repeated_source() -> None:
    item = WorkItem(tmdb_id=1, type="movie", title="X", year=2020)
    facts = [make_fact("A.", WIKI), make_fact("B.", WIKI), make_fact("C.", FANDOM)]
    trivia = assemble_title_trivia(item, facts, generated_at="2026-01-01T00:00:00Z")
    assert trivia.attribution == [WIKI, FANDOM]


def test_assemble_title_trivia_published_dict_strips_source_snippet() -> None:
    item = WorkItem(tmdb_id=1, type="movie", title="X", year=2020)
    trivia = assemble_title_trivia(item, [make_fact("A fact.")], generated_at="2026-01-01T00:00:00Z")
    d = trivia.to_published_dict()
    assert "source_snippet" not in json.dumps(d)
    assert set(d.keys()) == {"id", "type", "generatedAt", "pipelineVersion", "attribution", "facts"}


# --- build_publish_plan ---


def test_build_publish_plan_movie() -> None:
    item = WorkItem(tmdb_id=27205, type="movie", title="Inception", year=2010)
    facts = [make_fact("A fact.")]
    plan = build_publish_plan(item, facts, generated_at="2026-07-07T00:00:00Z")

    assert plan.key == "insights/movie/27205.json"
    assert plan.work_item_key == "movie:27205"
    assert plan.payload["id"] == "tmdb://27205"
    assert plan.payload["facts"][0]["text"] == "A fact."
    assert "source_snippet" not in plan.payload["facts"][0]


# --- WranglerUploader (subprocess mocked, not real wrangler) ---


def test_wrangler_uploader_invokes_remote_flag(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    captured_cmd = {}

    def fake_run(cmd, cwd=None, capture_output=True, text=True):
        captured_cmd["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, returncode=0, stdout="", stderr="")

    monkeypatch.setattr(subprocess, "run", fake_run)

    local_file = tmp_path / "payload.json"
    local_file.write_text("{}", encoding="utf-8")

    uploader = WranglerUploader(bucket="rivulet-insights")
    uploader.upload(local_file, "insights/movie/1.json")

    cmd = captured_cmd["cmd"]
    assert cmd[:4] == ["wrangler", "r2", "object", "put"]
    assert "rivulet-insights/insights/movie/1.json" in cmd
    assert "--remote" in cmd  # the load-bearing flag -- omitting it writes to local sim only


def test_wrangler_uploader_raises_publish_error_on_failure(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    def fake_run(cmd, cwd=None, capture_output=True, text=True):
        return subprocess.CompletedProcess(cmd, returncode=1, stdout="", stderr="not authenticated")

    monkeypatch.setattr(subprocess, "run", fake_run)

    local_file = tmp_path / "payload.json"
    local_file.write_text("{}", encoding="utf-8")

    uploader = WranglerUploader(bucket="rivulet-insights")
    with pytest.raises(PublishError, match="not authenticated"):
        uploader.upload(local_file, "insights/movie/1.json")


# --- IO helpers ---


def test_load_facts_verified_grouped_and_seed_index(tmp_path: Path) -> None:
    item = WorkItem(tmdb_id=1, type="movie", title="X", year=2020)
    write_seed_jsonl([item], tmp_path / "seed.jsonl")

    fact = make_fact("A fact.")
    result = VerifyBatchResult(key=item.key, verified=[fact], all_decisions=[])
    write_facts_verified_jsonl([result], tmp_path / "facts_verified.jsonl")

    facts_by_key = load_facts_verified_grouped(tmp_path / "facts_verified.jsonl")
    seed_index = load_seed_index(tmp_path / "seed.jsonl")

    assert facts_by_key[item.key][0].text == "A fact."
    assert seed_index[item.key] == item


# --- end-to-end run() with a fake uploader ---


class _FakeUploader:
    def __init__(self) -> None:
        self.uploaded: list[tuple[Path, str]] = []

    def upload(self, local_path: Path, key: str) -> None:
        self.uploaded.append((local_path, key))


def test_run_assembles_writes_and_uploads_all_verified_items(tmp_path: Path) -> None:
    from insights.config import Config

    config = Config(
        llm_base_url="http://fake/v1",
        llm_model="gemma4:31b-it-q4_K_M",
        llm_timeout_secs=5.0,
        llm_max_retries=1,
        data_dir=tmp_path,
        tmdb_proxy_base_url="https://tmdb-proxy.example",
        library_only=False,
        plex_base_url="",
        plex_token="",
        r2_endpoint_url="",
        r2_bucket="",
        r2_access_key_id="",
        r2_secret_access_key="",
    )

    movie_item = WorkItem(tmdb_id=1, type="movie", title="Movie A", year=2020)
    episode_item = WorkItem(tmdb_id=2, type="tv", title="Show B", year=2021, season=1, episode=2)
    no_facts_item = WorkItem(tmdb_id=3, type="movie", title="No Trivia", year=2019)
    write_seed_jsonl([movie_item, episode_item, no_facts_item], tmp_path / "seed.jsonl")

    results = [
        VerifyBatchResult(key=movie_item.key, verified=[make_fact("Movie fact.")], all_decisions=[]),
        VerifyBatchResult(key=episode_item.key, verified=[make_fact("Episode fact.", FANDOM)], all_decisions=[]),
        VerifyBatchResult(key=no_facts_item.key, verified=[], all_decisions=[]),
    ]
    write_facts_verified_jsonl(results, tmp_path / "facts_verified.jsonl")

    uploader = _FakeUploader()
    plans = run(config, uploader=uploader, generated_at="2026-07-07T00:00:00Z")

    assert len(plans) == 2  # no_facts_item skipped
    keys = {p.key for p in plans}
    assert keys == {"insights/movie/1.json", "insights/tv/2/1/2.json"}
    assert len(uploader.uploaded) == 2

    # Local published files were written with the correct payload shape.
    for local_path, key in uploader.uploaded:
        assert local_path.exists()
        payload = json.loads(local_path.read_text(encoding="utf-8"))
        assert payload["generatedAt"] == "2026-07-07T00:00:00Z"
        assert payload["pipelineVersion"] == 1


def test_run_skips_verified_item_with_no_matching_seed_entry(tmp_path: Path) -> None:
    from insights.config import Config

    config = Config(
        llm_base_url="http://fake/v1",
        llm_model="gemma4:31b-it-q4_K_M",
        llm_timeout_secs=5.0,
        llm_max_retries=1,
        data_dir=tmp_path,
        tmdb_proxy_base_url="https://tmdb-proxy.example",
        library_only=False,
        plex_base_url="",
        plex_token="",
        r2_endpoint_url="",
        r2_bucket="",
        r2_access_key_id="",
        r2_secret_access_key="",
    )
    write_seed_jsonl([], tmp_path / "seed.jsonl")  # empty seed, but facts_verified has an entry
    results = [VerifyBatchResult(key="movie:999", verified=[make_fact("Orphan fact.")], all_decisions=[])]
    write_facts_verified_jsonl(results, tmp_path / "facts_verified.jsonl")

    uploader = _FakeUploader()
    plans = run(config, uploader=uploader, generated_at="2026-07-07T00:00:00Z")

    assert plans == []
    assert uploader.uploaded == []


def _make_config(data_dir: Path):
    from insights.config import Config

    return Config(
        llm_base_url="http://fake/v1",
        llm_model="gemma4:31b-it-q4_K_M",
        llm_timeout_secs=5.0,
        llm_max_retries=1,
        data_dir=data_dir,
        tmdb_proxy_base_url="https://tmdb-proxy.example",
        library_only=False,
        plex_base_url="",
        plex_token="",
        r2_endpoint_url="",
        r2_bucket="",
        r2_access_key_id="",
        r2_secret_access_key="",
    )


def test_run_skips_show_level_tv_item_without_crashing_the_batch(tmp_path: Path) -> None:
    """Regression guard: a show-level TV WorkItem (no season/episode) that
    somehow reaches publish with facts attached must not raise out of the
    batch loop and take down every other title in the same run.
    """
    config = _make_config(tmp_path)

    good_item = WorkItem(tmdb_id=1, type="movie", title="Good Movie", year=2020)
    bad_item = WorkItem(tmdb_id=2, type="tv", title="Show-Level Only", year=2021)  # no season/episode
    write_seed_jsonl([good_item, bad_item], tmp_path / "seed.jsonl")

    results = [
        VerifyBatchResult(key=good_item.key, verified=[make_fact("Good fact.")], all_decisions=[]),
        VerifyBatchResult(key=bad_item.key, verified=[make_fact("Bad item fact.")], all_decisions=[]),
    ]
    write_facts_verified_jsonl(results, tmp_path / "facts_verified.jsonl")

    uploader = _FakeUploader()
    plans = run(config, uploader=uploader, generated_at="2026-07-07T00:00:00Z")

    assert [p.key for p in plans] == ["insights/movie/1.json"]
    assert len(uploader.uploaded) == 1


def test_run_upload_failure_for_one_title_does_not_crash_the_batch(tmp_path: Path) -> None:
    config = _make_config(tmp_path)

    good_item = WorkItem(tmdb_id=1, type="movie", title="Good Movie", year=2020)
    failing_item = WorkItem(tmdb_id=2, type="movie", title="Upload Fails", year=2021)
    write_seed_jsonl([good_item, failing_item], tmp_path / "seed.jsonl")

    results = [
        VerifyBatchResult(key=good_item.key, verified=[make_fact("Good fact.")], all_decisions=[]),
        VerifyBatchResult(key=failing_item.key, verified=[make_fact("Fact.")], all_decisions=[]),
    ]
    write_facts_verified_jsonl(results, tmp_path / "facts_verified.jsonl")

    class _PartiallyFailingUploader:
        def __init__(self) -> None:
            self.uploaded: list[tuple[Path, str]] = []

        def upload(self, local_path: Path, key: str) -> None:
            if "2.json" in key:
                raise PublishError("simulated upload failure")
            self.uploaded.append((local_path, key))

    uploader = _PartiallyFailingUploader()
    plans = run(config, uploader=uploader, generated_at="2026-07-07T00:00:00Z")

    assert [p.key for p in plans] == ["insights/movie/1.json"]
    assert len(uploader.uploaded) == 1
