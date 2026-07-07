"""Tests for the LLM chat client's JSON-array parsing + repair-retry logic.

No live network calls: `OllamaChatClient` is exercised via a fake `requests`
session (`FakeSession`) that returns canned responses.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import pytest

from insights.config import Config
from insights.llm import LLMError, OllamaChatClient, extract_json_array


def make_config() -> Config:
    return Config(
        llm_base_url="http://fake-ollama/v1",
        llm_model="gemma4:31b-it-q4_K_M",
        llm_timeout_secs=5.0,
        llm_max_retries=1,
        data_dir=Path("./data"),
        tmdb_proxy_base_url="https://tmdb-proxy.example",
        plex_base_url="",
        plex_token="",
        r2_endpoint_url="",
        r2_bucket="",
        r2_access_key_id="",
        r2_secret_access_key="",
    )


class FakeResponse:
    def __init__(self, content: str, status: int = 200) -> None:
        self._content = content
        self.status_code = status

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            import requests

            raise requests.HTTPError(f"HTTP {self.status_code}")

    def json(self) -> dict[str, Any]:
        return {"choices": [{"message": {"content": self._content}}]}


@dataclass
class FakeSession:
    """Fake `requests.Session` returning a scripted sequence of replies."""

    replies: list[str] = field(default_factory=list)
    calls: list[dict[str, Any]] = field(default_factory=list)

    def post(self, url: str, json: dict[str, Any], timeout: float) -> FakeResponse:
        self.calls.append({"url": url, "json": json, "timeout": timeout})
        if not self.replies:
            raise AssertionError("FakeSession ran out of scripted replies")
        return FakeResponse(self.replies.pop(0))


# --- extract_json_array (pure) ---


def test_extract_json_array_plain() -> None:
    assert extract_json_array('[{"a": 1}]') == [{"a": 1}]


def test_extract_json_array_strips_markdown_fence() -> None:
    text = '```json\n[{"a": 1}, {"b": 2}]\n```'
    assert extract_json_array(text) == [{"a": 1}, {"b": 2}]


def test_extract_json_array_strips_surrounding_prose() -> None:
    text = 'Sure, here is the array:\n[{"a": 1}]\nHope that helps!'
    assert extract_json_array(text) == [{"a": 1}]


def test_extract_json_array_returns_none_for_object() -> None:
    assert extract_json_array('{"a": 1}') is None


def test_extract_json_array_returns_none_for_garbage() -> None:
    assert extract_json_array("not json at all") is None


def test_extract_json_array_empty_array() -> None:
    assert extract_json_array("[]") == []


# --- OllamaChatClient ---


def test_chat_returns_message_content() -> None:
    session = FakeSession(replies=["hello world"])
    client = OllamaChatClient(config=make_config(), session=session)
    assert client.chat("sys", "user") == "hello world"
    assert session.calls[0]["json"]["model"] == "gemma4:31b-it-q4_K_M"
    assert session.calls[0]["json"]["messages"][0] == {"role": "system", "content": "sys"}


def test_chat_json_array_parses_clean_reply() -> None:
    session = FakeSession(replies=['[{"text": "fact one"}]'])
    client = OllamaChatClient(config=make_config(), session=session)
    result = client.chat_json_array("sys", "user")
    assert result == [{"text": "fact one"}]
    assert len(session.calls) == 1


def test_chat_json_array_repairs_malformed_reply() -> None:
    session = FakeSession(
        replies=["here's your data: {not valid json", '[{"text": "fixed"}]']
    )
    client = OllamaChatClient(config=make_config(), session=session)
    result = client.chat_json_array("sys", "user")
    assert result == [{"text": "fixed"}]
    assert len(session.calls) == 2  # original + one repair retry


def test_chat_json_array_raises_after_failed_repair() -> None:
    session = FakeSession(replies=["garbage", "still garbage"])
    client = OllamaChatClient(config=make_config(), session=session)
    with pytest.raises(LLMError):
        client.chat_json_array("sys", "user")


def test_post_retries_on_request_exception_then_succeeds() -> None:
    import requests

    class FlakySession:
        def __init__(self) -> None:
            self.attempts = 0

        def post(self, url: str, json: dict[str, Any], timeout: float) -> FakeResponse:
            self.attempts += 1
            if self.attempts == 1:
                raise requests.ConnectionError("boom")
            return FakeResponse('[{"ok": true}]')

    client = OllamaChatClient(config=make_config(), session=FlakySession())
    assert client.chat_json_array("sys", "user") == [{"ok": True}]


def test_post_raises_llmerror_after_exhausting_retries() -> None:
    import requests

    class AlwaysFails:
        def post(self, url: str, json: dict[str, Any], timeout: float) -> FakeResponse:
            raise requests.ConnectionError("nope")

    client = OllamaChatClient(config=make_config(), session=AlwaysFails())
    with pytest.raises(LLMError):
        client.chat("sys", "user")
