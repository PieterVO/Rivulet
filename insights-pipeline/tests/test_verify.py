"""Tests for the strengthened verify stage (bakeoff/DECISION.md).

Covers the four strengthened behaviors on top of the original grounding/
spoiler re-check: malformed-record rejection, filler-drop, dedup, and
category-fix — plus keep/drop LLM-call outcomes. All LLM interaction goes
through a fake ChatClient; no live calls.
"""

from __future__ import annotations

from pathlib import Path

from insights.models import Fact, Source
from insights.stages.verify import (
    VerifyDecision,
    apply_verify_reply,
    build_verify_user_prompt,
    dedup_facts,
    is_filler_fact,
    load_facts_verified_jsonl,
    looks_truncated,
    parse_verify_reply,
    reject_malformed,
    render_spot_check_report,
    verify_batch,
    write_facts_verified_jsonl,
)

SRC = Source(name="Wikipedia", url="https://en.wikipedia.org/wiki/Example")


def make_fact(text: str, category: str = "production", spoiler: int = 0, snippet: str = "") -> Fact:
    return Fact(text=text, category=category, spoiler=spoiler, source=SRC, source_snippet=snippet or text)


# --- 1. malformed rejection ---


def test_looks_truncated_short_text() -> None:
    assert looks_truncated("Short.")
    assert looks_truncated("")
    assert looks_truncated("   ")


def test_looks_truncated_dangling_conjunction() -> None:
    assert looks_truncated("The director wanted practical effects and")
    assert looks_truncated("The set was built over several weeks, with")


def test_looks_truncated_trailing_punctuation() -> None:
    assert looks_truncated("The film was shot on location,")


def test_looks_truncated_false_for_complete_sentence() -> None:
    assert not looks_truncated("The film was shot on location in Iceland over six weeks.")


def test_reject_malformed_drops_truncated_and_empty() -> None:
    good = make_fact("The film was shot on location in Iceland over six weeks.")
    truncated = make_fact("The director wanted practical effects and")
    empty = make_fact("   ")

    kept, rejected = reject_malformed([good, truncated, empty])

    assert kept == [good]
    assert len(rejected) == 2
    assert all(not d.kept for d in rejected)
    assert any("truncated" in d.reason for d in rejected)


def test_reject_malformed_drops_invalid_category_and_spoiler() -> None:
    bad_category = Fact("A perfectly complete sentence here.", "not-a-real-category", 0, SRC, "s")
    bad_spoiler = Fact("Another perfectly complete sentence.", "production", 7, SRC, "s")

    kept, rejected = reject_malformed([bad_category, bad_spoiler])

    assert kept == []
    assert len(rejected) == 2
    assert any("invalid category" in d.reason for d in rejected)
    assert any("invalid spoiler" in d.reason for d in rejected)


def test_reject_malformed_drops_missing_source_url() -> None:
    no_url = Fact("A perfectly complete sentence here.", "production", 0, Source("W", ""), "s")
    kept, rejected = reject_malformed([no_url])
    assert kept == []
    assert "missing source url" in rejected[0].reason


def test_reject_malformed_keeps_good_facts_untouched() -> None:
    good = make_fact("The film was shot on location in Iceland over six weeks.")
    kept, rejected = reject_malformed([good])
    assert kept == [good]
    assert rejected == []


# --- 2. filler detection ---


def test_is_filler_fact_bare_role_listing() -> None:
    assert is_filler_fact("John Krasinski played Jim Halpert.")
    assert is_filler_fact("Steve Carell portrays Michael Scott")
    assert is_filler_fact("Rainn Wilson plays Dwight Schrute.")


def test_is_filler_fact_false_when_fact_has_substance() -> None:
    assert not is_filler_fact(
        "John Krasinski played Jim Halpert after auditioning for the role of Dwight instead."
    )
    assert not is_filler_fact(
        "Steve Carell was cast as Michael Scott following a lengthy negotiation."
    )


def test_is_filler_fact_false_for_unrelated_sentence() -> None:
    assert not is_filler_fact("The set was built on a soundstage in Van Nuys, California.")


# --- 3. dedup ---


def test_dedup_facts_exact_duplicate_text() -> None:
    a = make_fact("The set rotated 360 degrees during filming.")
    b = make_fact("The set rotated 360 degrees during filming.")
    kept, rejected = dedup_facts([a, b])
    assert kept == [a]
    assert len(rejected) == 1
    assert "duplicate" in rejected[0].reason


def test_dedup_facts_near_duplicate_restatement() -> None:
    a = make_fact("The director shot the corridor fight scene using a rotating set instead of CGI.")
    b = make_fact("The corridor fight scene was shot using a rotating set rather than CGI by the director.")
    kept, _rejected = dedup_facts([a, b])
    assert kept == [a]


def test_dedup_facts_keeps_distinct_facts() -> None:
    a = make_fact("The film was shot in Iceland over six weeks.")
    b = make_fact("The composer recorded the score with a live orchestra in London.")
    kept, rejected = dedup_facts([a, b])
    assert kept == [a, b]
    assert rejected == []


def test_dedup_facts_keeps_distinct_short_facts_sharing_scaffold() -> None:
    # Regression: two DISTINCT short facts that share sentence scaffolding
    # ("the score was ... by X") must not be deduped. With raw tokens these
    # scored ~0.75 and the second was wrongly dropped; stopword-stripping
    # reduces them to {score, composed, hans, zimmer} vs {score, recorded,
    # hans, zimmer} → Jaccard 0.5, correctly kept.
    a = make_fact("The score was composed by Hans Zimmer.")
    b = make_fact("The score was recorded by Hans Zimmer.")
    kept, rejected = dedup_facts([a, b])
    assert kept == [a, b]
    assert rejected == []


def test_dedup_facts_empty_list() -> None:
    assert dedup_facts([]) == ([], [])


# --- LLM verify reply parsing + application ---


def test_parse_verify_reply_plain_json() -> None:
    reply = parse_verify_reply('{"grounded": true, "category": "production", "spoiler": 0}')
    assert reply == {"grounded": True, "category": "production", "spoiler": 0}


def test_parse_verify_reply_strips_markdown_fence() -> None:
    reply = parse_verify_reply('```json\n{"grounded": false, "category": "lore", "spoiler": 1}\n```')
    assert reply == {"grounded": False, "category": "lore", "spoiler": 1}


def test_parse_verify_reply_extracts_from_surrounding_prose() -> None:
    reply = parse_verify_reply('Here is my judgement: {"grounded": true, "category": "goof", "spoiler": 0} done.')
    assert reply == {"grounded": True, "category": "goof", "spoiler": 0}


def test_parse_verify_reply_unparseable_returns_none() -> None:
    assert parse_verify_reply("not json at all") is None


def test_build_verify_user_prompt_includes_snippet_and_tags() -> None:
    fact = make_fact("A fact.", category="casting", spoiler=1, snippet="Original snippet text.")
    prompt = build_verify_user_prompt(fact)
    assert "Original snippet text." in prompt
    assert "A fact." in prompt
    assert "casting" in prompt
    assert "1" in prompt


def test_apply_verify_reply_keeps_grounded_fact() -> None:
    fact = make_fact("A fact.", category="production", spoiler=0)
    decision = apply_verify_reply(fact, {"grounded": True, "category": "production", "spoiler": 0})
    assert decision.kept is True
    assert decision.fact.category == "production"


def test_apply_verify_reply_drops_ungrounded_fact() -> None:
    fact = make_fact("A fact.")
    decision = apply_verify_reply(fact, {"grounded": False, "category": "production", "spoiler": 0})
    assert decision.kept is False
    assert "ungrounded" in decision.reason


def test_apply_verify_reply_drops_on_unparseable_reply() -> None:
    fact = make_fact("A fact.")
    decision = apply_verify_reply(fact, None)
    assert decision.kept is False
    assert "unparseable" in decision.reason


def test_apply_verify_reply_fixes_category_mistag() -> None:
    fact = make_fact("The anecdote is about a production choice.", category="casting", spoiler=0)
    decision = apply_verify_reply(fact, {"grounded": True, "category": "production", "spoiler": 0})
    assert decision.kept is True
    assert decision.fact.category == "production"  # corrected from casting


def test_apply_verify_reply_fixes_spoiler_recheck() -> None:
    fact = make_fact("A reveal.", category="lore", spoiler=0)
    decision = apply_verify_reply(fact, {"grounded": True, "category": "lore", "spoiler": 2})
    assert decision.kept is True
    assert decision.fact.spoiler == 2  # corrected from 0


def test_apply_verify_reply_ignores_invalid_category_fix_keeps_original() -> None:
    fact = make_fact("A fact.", category="production", spoiler=0)
    decision = apply_verify_reply(fact, {"grounded": True, "category": "not-real", "spoiler": 0})
    assert decision.kept is True
    assert decision.fact.category == "production"


def test_apply_verify_reply_tolerates_string_spoiler() -> None:
    fact = make_fact("A fact.", category="production", spoiler=0)
    decision = apply_verify_reply(fact, {"grounded": True, "category": "production", "spoiler": "1"})
    assert decision.kept is True
    assert decision.fact.spoiler == 1


# --- batch orchestration (fake ChatClient) ---


class _FakeChatClient:
    """Fake ChatClient: scripted `chat()` replies, one per call, in order."""

    def __init__(self, replies: list[str]) -> None:
        self._replies = list(replies)
        self.calls: list[str] = []

    def chat(self, system_prompt: str, user_prompt: str) -> str:
        self.calls.append(user_prompt)
        return self._replies.pop(0)

    def chat_json_array(self, system_prompt: str, user_prompt: str) -> list:
        raise NotImplementedError


def test_verify_batch_full_pipeline_keep_drop_dedup_filler_malformed() -> None:
    good = make_fact("The film was shot on location in Iceland over six weeks by the crew.")
    truncated = make_fact("The director insisted on practical effects and")
    filler = make_fact("John Krasinski played Jim Halpert.")
    dup = make_fact("The film was shot on location in Iceland over six weeks by the crew.")
    ungrounded_candidate = make_fact("The composer recorded a full symphonic score in Prague.")

    facts = [good, truncated, filler, dup, ungrounded_candidate]

    chat_client = _FakeChatClient(
        [
            '{"grounded": true, "category": "production", "spoiler": 0}',  # for `good`
            '{"grounded": false, "category": "music", "spoiler": 0}',  # for ungrounded_candidate
        ]
    )

    result = verify_batch(chat_client, "movie:1", facts)

    assert [f.text for f in result.verified] == [good.text]
    assert len(result.all_decisions) == 5
    reasons = {d.fact.text: d.reason for d in result.all_decisions if not d.kept}
    assert "truncated" in reasons[truncated.text]
    assert "filler" in reasons[filler.text]
    assert "duplicate" in reasons[dup.text]
    assert "ungrounded" in reasons[ungrounded_candidate.text]
    assert result.drop_rate == 4 / 5


def test_verify_batch_llm_call_failure_drops_fact() -> None:
    good = make_fact("The film was shot on location in Iceland over six weeks by the crew.")

    class _FailingChatClient:
        def chat(self, system_prompt: str, user_prompt: str) -> str:
            from insights.llm import LLMError

            raise LLMError("connection refused")

        def chat_json_array(self, system_prompt: str, user_prompt: str) -> list:
            raise NotImplementedError

    result = verify_batch(_FailingChatClient(), "movie:1", [good])
    assert result.verified == []
    assert "verify call failed" in result.all_decisions[0].reason


def test_verify_batch_empty_input() -> None:
    result = verify_batch(_FakeChatClient([]), "movie:1", [])
    assert result.verified == []
    assert result.drop_rate == 0.0


# --- report + jsonl IO ---


def test_render_spot_check_report_includes_facts_and_drop_rate() -> None:
    from insights.stages.verify import VerifyBatchResult

    kept_decision = VerifyDecision(make_fact("Good fact here that is complete."), True, "")
    dropped_decision = VerifyDecision(make_fact("Bad fact."), False, "ungrounded: test reason")
    result = VerifyBatchResult(key="movie:1", verified=[kept_decision.fact], all_decisions=[kept_decision, dropped_decision])

    html_out = render_spot_check_report([result])

    assert "Good fact here that is complete." in html_out
    assert "Bad fact." in html_out
    assert "ungrounded: test reason" in html_out
    assert "50%" in html_out  # 1/2 dropped
    assert "en.wikipedia.org" in html_out


def test_write_and_load_facts_verified_jsonl_round_trip(tmp_path: Path) -> None:
    from insights.stages.verify import VerifyBatchResult

    fact = make_fact("A verified fact.")
    result = VerifyBatchResult(key="movie:1", verified=[fact], all_decisions=[VerifyDecision(fact, True, "")])
    path = tmp_path / "facts_verified.jsonl"
    write_facts_verified_jsonl([result], path)

    loaded = load_facts_verified_jsonl(path)
    assert set(loaded.keys()) == {"movie:1"}
    assert loaded["movie:1"][0].text == "A verified fact."


def test_load_facts_verified_jsonl_missing_file_returns_empty(tmp_path: Path) -> None:
    assert load_facts_verified_jsonl(tmp_path / "nope.jsonl") == {}


# --- run() IO shell: resume path must not silently drop cached facts from the drop-rate stat ---


def test_run_resumed_item_counts_as_kept_not_dropped_from_stats(tmp_path: Path) -> None:
    from insights.config import Config
    from insights.stages.verify import run

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

    # Simulate a prior run already having verified "movie:1".
    from insights.stages.verify import VerifyBatchResult as _VBR

    already = _VBR(key="movie:1", verified=[make_fact("Already verified fact.")], all_decisions=[])
    write_facts_verified_jsonl([already], tmp_path / "facts_verified.jsonl")

    # This run only supplies a NEW item; movie:1's raw facts aren't even
    # passed in, matching how a real resumed run would only re-process
    # what's missing from facts_verified.jsonl.
    results = run(config, facts_by_key={"movie:1": [], "movie:2": [make_fact("New fact.")]})

    resumed = next(r for r in results if r.key == "movie:1")
    assert resumed.verified == [already.verified[0]]
    # The cached survivor must be represented as a kept decision, not
    # vanish from the denominator (regression guard).
    assert len(resumed.all_decisions) == 1
    assert resumed.all_decisions[0].kept is True
    assert resumed.drop_rate == 0.0
