"""Tests for the extract stage: schema mapping, attribution, and the
per-section extraction flow, all against a fake ChatClient. No live LLM
calls.
"""

from __future__ import annotations

from pathlib import Path

from insights.models import Fact, Source
from insights.stages.extract import (
    PROMPT_PATH,
    attribution_source_for,
    extract_page,
    extract_section,
    load_facts_raw_jsonl,
    load_extract_prompt,
    raw_fact_to_fact,
    write_facts_raw_jsonl,
)
from insights.stages.fetch import FetchedPage, WikiSection


class _FakeChatClient:
    """Fake ChatClient returning one scripted `chat_json_array` reply per call, in order."""

    def __init__(self, replies: list[list[object]]) -> None:
        self._replies = list(replies)
        self.calls: list[tuple[str, str]] = []

    def chat(self, system_prompt: str, user_prompt: str) -> str:
        raise NotImplementedError

    def chat_json_array(self, system_prompt: str, user_prompt: str) -> list[object]:
        self.calls.append((system_prompt, user_prompt))
        return self._replies.pop(0)


class _FailingChatClient:
    def chat(self, system_prompt: str, user_prompt: str) -> str:
        raise NotImplementedError

    def chat_json_array(self, system_prompt: str, user_prompt: str) -> list[object]:
        from insights.llm import LLMError

        raise LLMError("boom")


def test_prompt_file_exists_and_loads() -> None:
    assert PROMPT_PATH.exists()
    prompt = load_extract_prompt()
    assert "JSON array" in prompt


def test_attribution_source_for_wikipedia() -> None:
    page = FetchedPage(url="https://en.wikipedia.org/wiki/Inception", title="Inception", sections=[])
    source = attribution_source_for(page)
    assert source == Source(name="Wikipedia", url="https://en.wikipedia.org/wiki/Inception")


def test_attribution_source_for_fandom() -> None:
    page = FetchedPage(url="https://silo.fandom.com/wiki/Silo_(TV_series)", title="Silo", sections=[])
    source = attribution_source_for(page)
    assert source.name == "Silo Wiki"
    assert source.url == "https://silo.fandom.com/wiki/Silo_(TV_series)"


def test_raw_fact_to_fact_valid() -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    raw = {"text": "The set rotated 360 degrees.", "category": "production", "spoiler": 0, "source": "Production"}
    fact = raw_fact_to_fact(raw, source, source_snippet="original section text")
    assert fact == Fact(
        text="The set rotated 360 degrees.",
        category="production",
        spoiler=0,
        source=source,
        source_snippet="original section text",
    )


def test_raw_fact_to_fact_tolerates_string_spoiler() -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    raw = {"text": "A fact.", "category": "lore", "spoiler": "1", "source": "Lore"}
    fact = raw_fact_to_fact(raw, source, source_snippet="s")
    assert fact is not None
    assert fact.spoiler == 1


def test_raw_fact_to_fact_rejects_bad_category() -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    raw = {"text": "A fact.", "category": "bogus", "spoiler": 0, "source": "X"}
    assert raw_fact_to_fact(raw, source, "s") is None


def test_raw_fact_to_fact_rejects_bad_spoiler() -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    raw = {"text": "A fact.", "category": "production", "spoiler": 9, "source": "X"}
    assert raw_fact_to_fact(raw, source, "s") is None


def test_raw_fact_to_fact_rejects_missing_text() -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    assert raw_fact_to_fact({"category": "production", "spoiler": 0}, source, "s") is None
    assert raw_fact_to_fact({"text": "", "category": "production", "spoiler": 0}, source, "s") is None


def test_raw_fact_to_fact_rejects_non_dict() -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    assert raw_fact_to_fact("not a dict", source, "s") is None
    assert raw_fact_to_fact(None, source, "s") is None


def test_raw_fact_to_fact_carries_through_valid_interest() -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    raw = {
        "text": "A fact.",
        "category": "production",
        "spoiler": 0,
        "source": "X",
        "interest": 8,
    }
    fact = raw_fact_to_fact(raw, source, "s")
    assert fact is not None
    assert fact.interest == 8


def test_raw_fact_to_fact_defaults_interest_missing() -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    raw = {"text": "A fact.", "category": "production", "spoiler": 0, "source": "X"}
    fact = raw_fact_to_fact(raw, source, "s")
    assert fact is not None
    assert fact.interest == 0


def test_extract_section_maps_llm_facts_and_attaches_snippet() -> None:
    section = WikiSection(heading="Production", level=2, body="The set rotated 360 degrees.")
    source = Source(name="Wikipedia", url="https://w/x")
    chat_client = _FakeChatClient(
        [[{"text": "The set rotated 360 degrees.", "category": "production", "spoiler": 0, "source": "Production"}]]
    )

    facts = extract_section(chat_client, section, source, system_prompt="SYS")

    assert len(facts) == 1
    assert facts[0].source_snippet == "The set rotated 360 degrees."
    assert facts[0].source == source
    # The section body (not the system prompt) is what's sent as the user message.
    assert chat_client.calls[0] == ("SYS", "The set rotated 360 degrees.")


def test_extract_section_drops_malformed_entries_without_crashing() -> None:
    section = WikiSection(heading="Production", level=2, body="Some text.")
    source = Source(name="Wikipedia", url="https://w/x")
    chat_client = _FakeChatClient(
        [
            [
                {"text": "Good fact.", "category": "production", "spoiler": 0},
                {"text": "", "category": "production", "spoiler": 0},  # dropped: empty text
                {"category": "production", "spoiler": 0},  # dropped: missing text
                "not even a dict",  # dropped
            ]
        ]
    )

    facts = extract_section(chat_client, section, source, system_prompt="SYS")
    assert len(facts) == 1
    assert facts[0].text == "Good fact."


def test_extract_section_llm_failure_yields_empty_list() -> None:
    section = WikiSection(heading="Production", level=2, body="Some text.")
    source = Source(name="Wikipedia", url="https://w/x")
    facts = extract_section(_FailingChatClient(), section, source, system_prompt="SYS")
    assert facts == []


def test_extract_page_concatenates_facts_across_sections() -> None:
    page = FetchedPage(
        url="https://en.wikipedia.org/wiki/Example",
        title="Example",
        sections=[
            WikiSection(heading="Production", level=2, body="Prod text."),
            WikiSection(heading="Casting", level=2, body="Cast text."),
        ],
    )
    chat_client = _FakeChatClient(
        [
            [{"text": "Prod fact.", "category": "production", "spoiler": 0}],
            [{"text": "Cast fact.", "category": "casting", "spoiler": 0}],
        ]
    )

    facts = extract_page(chat_client, page, system_prompt="SYS")

    assert [f.text for f in facts] == ["Prod fact.", "Cast fact."]
    assert all(f.source.name == "Wikipedia" for f in facts)
    assert len(chat_client.calls) == 2


def test_write_and_load_facts_raw_jsonl_round_trip(tmp_path: Path) -> None:
    source = Source(name="Wikipedia", url="https://w/x")
    facts_by_key = {
        "movie:1": [Fact("A fact.", "production", 0, source, source_snippet="snip")],
        "tv:2:S1E1": [],
    }
    path = tmp_path / "facts_raw.jsonl"
    write_facts_raw_jsonl(facts_by_key, path)

    loaded = load_facts_raw_jsonl(path)
    assert set(loaded.keys()) == {"movie:1", "tv:2:S1E1"}
    assert loaded["movie:1"][0].text == "A fact."
    assert loaded["movie:1"][0].source_snippet == "snip"
    assert loaded["tv:2:S1E1"] == []


def test_load_facts_raw_jsonl_missing_file_returns_empty(tmp_path: Path) -> None:
    assert load_facts_raw_jsonl(tmp_path / "nope.jsonl") == {}
