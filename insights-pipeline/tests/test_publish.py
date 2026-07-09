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
from insights.stages.seed import WorkItem, load_published_keys, load_published_records, write_seed_jsonl
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


def test_derive_object_key_show_level_tv() -> None:
    # Show-level TV trivia (production/casting/overall, not tied to an episode)
    # keys to insights/tv/{id}/show.json.
    item = WorkItem(tmdb_id=2802, type="tv", title="Silo", year=2023)  # no season/episode
    assert derive_object_key(item) == "insights/tv/2802/show.json"


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
    assert trivia.pipeline_version == 2
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
    assert set(d.keys()) == {
        "id",
        "type",
        "generatedAt",
        "pipelineVersion",
        "covered",
        "releaseDate",
        "attribution",
        "facts",
    }


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


def test_zero_facts_publishes_tombstone() -> None:
    # NOTE: the plan names this function `assemble_publish_plan`; the
    # existing codebase already has an equivalent `build_publish_plan`
    # (same signature/intent), so this uses that name rather than
    # introducing a duplicate.
    w = WorkItem(
        tmdb_id=125988, type="tv", title="Silo", year=2023, season=3, episode=4,
        release_date="2025-01-01",
    )
    plan = build_publish_plan(w, facts=[], generated_at="2026-07-07T00:00:00Z")
    assert plan.payload["covered"] is False
    assert plan.payload["facts"] == []
    assert plan.payload["releaseDate"] == "2025-01-01"
    assert plan.key == "insights/tv/125988/3/4.json"


def test_facts_present_publishes_covered() -> None:
    w = WorkItem(tmdb_id=27205, type="movie", title="Inception", year=2010, release_date="2010-07-16")
    f = make_fact("A fact.")
    plan = build_publish_plan(w, facts=[f], generated_at="2026-07-07T00:00:00Z")
    assert plan.payload["covered"] is True
    assert len(plan.payload["facts"]) == 1
    assert plan.payload["releaseDate"] == "2010-07-16"


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
    from tests.helpers import make_config as _make_cfg

    config = _make_cfg(data_dir=tmp_path)

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

    # no_facts_item publishes too -- as a tombstone (covered=False), not a skip.
    assert len(plans) == 3
    keys = {p.key for p in plans}
    assert keys == {"insights/movie/1.json", "insights/tv/2/1/2.json", "insights/movie/3.json"}
    assert len(uploader.uploaded) == 3

    tombstone_plan = next(p for p in plans if p.key == "insights/movie/3.json")
    assert tombstone_plan.payload["covered"] is False
    assert tombstone_plan.payload["facts"] == []

    # Local published files were written with the correct payload shape.
    for local_path, key in uploader.uploaded:
        assert local_path.exists()
        payload = json.loads(local_path.read_text(encoding="utf-8"))
        assert payload["generatedAt"] == "2026-07-07T00:00:00Z"
        assert payload["pipelineVersion"] == 2


def test_run_skips_verified_item_with_no_matching_seed_entry(tmp_path: Path) -> None:
    from tests.helpers import make_config

    config = make_config(data_dir=tmp_path)
    write_seed_jsonl([], tmp_path / "seed.jsonl")  # empty seed, but facts_verified has an entry
    results = [VerifyBatchResult(key="movie:999", verified=[make_fact("Orphan fact.")], all_decisions=[])]
    write_facts_verified_jsonl(results, tmp_path / "facts_verified.jsonl")

    uploader = _FakeUploader()
    plans = run(config, uploader=uploader, generated_at="2026-07-07T00:00:00Z")

    assert plans == []
    assert uploader.uploaded == []


def _make_config(data_dir: Path):
    from tests.helpers import make_config

    return make_config(data_dir=data_dir)


def test_run_publishes_show_level_tv_item(tmp_path: Path) -> None:
    """A show-level TV WorkItem (no season/episode) publishes to the show-level
    key alongside a movie in the same batch — production/casting/overall trivia
    (e.g. from a show's Wikipedia article) has a home.
    """
    config = _make_config(tmp_path)

    movie_item = WorkItem(tmdb_id=1, type="movie", title="Good Movie", year=2020)
    show_item = WorkItem(tmdb_id=2, type="tv", title="Show-Level Only", year=2021)  # no season/episode
    write_seed_jsonl([movie_item, show_item], tmp_path / "seed.jsonl")

    results = [
        VerifyBatchResult(key=movie_item.key, verified=[make_fact("Movie fact.")], all_decisions=[]),
        VerifyBatchResult(key=show_item.key, verified=[make_fact("Show fact.")], all_decisions=[]),
    ]
    write_facts_verified_jsonl(results, tmp_path / "facts_verified.jsonl")

    uploader = _FakeUploader()
    plans = run(config, uploader=uploader, generated_at="2026-07-07T00:00:00Z")

    assert {p.key for p in plans} == {"insights/movie/1.json", "insights/tv/2/show.json"}
    assert len(uploader.uploaded) == 2


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


# --- published.jsonl manifest wiring (feeds seed's episode-freshness filter) ---


def test_run_appends_published_manifest_for_successful_uploads_only(tmp_path: Path) -> None:
    config = _make_config(tmp_path)

    good_item = WorkItem(tmdb_id=1, type="movie", title="Good Movie", year=2020)
    episode_item = WorkItem(tmdb_id=2, type="tv", title="Show B", year=2021, season=1, episode=2)
    failing_item = WorkItem(tmdb_id=3, type="movie", title="Upload Fails", year=2021)
    write_seed_jsonl([good_item, episode_item, failing_item], tmp_path / "seed.jsonl")

    results = [
        VerifyBatchResult(key=good_item.key, verified=[make_fact("A.")], all_decisions=[]),
        VerifyBatchResult(key=episode_item.key, verified=[make_fact("B.", FANDOM)], all_decisions=[]),
        VerifyBatchResult(key=failing_item.key, verified=[make_fact("C.")], all_decisions=[]),
    ]
    write_facts_verified_jsonl(results, tmp_path / "facts_verified.jsonl")

    class _PartiallyFailingUploader:
        def upload(self, local_path: Path, key: str) -> None:
            if "3.json" in key:
                raise PublishError("simulated upload failure")

    run(config, uploader=_PartiallyFailingUploader(), generated_at="2026-07-07T00:00:00Z")

    published_keys = load_published_keys(tmp_path / "published.jsonl")
    assert published_keys == {good_item.key, episode_item.key}  # failing_item's upload never succeeded


def test_run_with_no_published_items_does_not_create_manifest_file(tmp_path: Path) -> None:
    config = _make_config(tmp_path)
    write_seed_jsonl([], tmp_path / "seed.jsonl")
    write_facts_verified_jsonl([], tmp_path / "facts_verified.jsonl")

    run(config, uploader=_FakeUploader(), generated_at="2026-07-07T00:00:00Z")

    assert not (tmp_path / "published.jsonl").exists()


def test_tombstone_publish_appends_manifest(tmp_path: Path) -> None:
    """A title with zero verified facts still publishes (a tombstone) and
    still gets a published.jsonl record -- with covered:false -- so the
    scheduled TTL-refresh's staleness check (and the client's 404 handling)
    see it as answered, not missing.
    """
    config = _make_config(tmp_path)

    no_facts_item = WorkItem(tmdb_id=1, type="movie", title="Nothing Found", year=2019)
    write_seed_jsonl([no_facts_item], tmp_path / "seed.jsonl")
    results = [VerifyBatchResult(key=no_facts_item.key, verified=[], all_decisions=[])]
    write_facts_verified_jsonl(results, tmp_path / "facts_verified.jsonl")

    run(config, uploader=_FakeUploader(), generated_at="2026-07-07T00:00:00Z")

    records = load_published_records(tmp_path / "published.jsonl")
    assert len(records) == 1
    assert records[0]["key"] == no_facts_item.key
    assert records[0]["covered"] is False
    assert records[0]["published_at"] == "2026-07-07T00:00:00Z"


def test_select_uploader_prefers_explicit() -> None:
    from insights.stages.publish import select_uploader

    explicit = _FakeUploader()
    assert select_uploader(_make_config(Path("/tmp/x")), explicit, "bucket") is explicit


def test_select_uploader_boto3_when_r2_configured() -> None:
    from insights.stages.publish import Boto3Uploader, select_uploader
    from tests.helpers import make_config

    cfg = make_config(
        r2_endpoint_url="https://acct.r2.cloudflarestorage.com",
        r2_bucket="rivulet-insights",
        r2_access_key_id="key",
        r2_secret_access_key="secret",
    )
    assert isinstance(select_uploader(cfg, None, "rivulet-insights"), Boto3Uploader)


def test_select_uploader_wrangler_when_not_configured() -> None:
    from insights.stages.publish import WranglerUploader, select_uploader

    # No R2 S3 creds -> interactive wrangler-OAuth path (the box default).
    up = select_uploader(_make_config(Path("/tmp/x")), None, "rivulet-insights")
    assert isinstance(up, WranglerUploader)


def test_run_tombstones_seed_item_absent_from_verified(tmp_path: Path) -> None:
    # A no-source item is dropped before verify (fetch produces no sections), so
    # it never appears in facts_verified. publish must STILL tombstone it -- it
    # iterates the SEED, not the verified facts -- so "nothing to share" is
    # definitive and the client/worker stop re-attempting it.
    config = _make_config(tmp_path)
    item = WorkItem(tmdb_id=125988, type="tv", title="Silo", year=2023, season=1, episode=2)
    write_seed_jsonl([item], tmp_path / "seed.jsonl")
    # No facts_verified.jsonl written at all (the no-source case).
    run(config, uploader=_FakeUploader(), generated_at="2026-07-07T00:00:00Z")
    records = load_published_records(tmp_path / "published.jsonl")
    assert [r["key"] for r in records] == [item.key]
    assert records[0]["covered"] is False


def test_run_ignores_verified_key_not_in_seed(tmp_path: Path) -> None:
    # Leftover verified facts for a key NOT in this batch's seed (accumulated
    # prior-run on-disk state) must NOT be published -- only seed items are.
    config = _make_config(tmp_path)
    item = WorkItem(tmdb_id=1, type="movie", title="A", year=2020)
    write_seed_jsonl([item], tmp_path / "seed.jsonl")
    leftover = VerifyBatchResult(key="tv:999:S1E1", verified=[make_fact("stale")], all_decisions=[])
    write_facts_verified_jsonl([leftover], tmp_path / "facts_verified.jsonl")
    run(config, uploader=_FakeUploader(), generated_at="2026-07-07T00:00:00Z")
    records = load_published_records(tmp_path / "published.jsonl")
    assert [r["key"] for r in records] == [item.key]   # only the seed item...
    assert records[0]["covered"] is False               # ...tombstoned (no verified facts of its own)
