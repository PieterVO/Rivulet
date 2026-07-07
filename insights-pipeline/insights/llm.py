"""OpenAI-compatible chat client for the extract + verify stages.

Talks to whatever `Config.llm_base_url` points at (Ollama's `/v1` by
default, but any OpenAI-compatible endpoint works — model-agnostic per the
plan's global constraints). The only contract this module cares about is
`POST {base_url}/chat/completions` returning the standard
`{"choices": [{"message": {"content": "..."}}]}` shape.

Extract/verify both need "ask the model for a JSON array back"; this module
owns that pattern once: send messages, get content back, parse it as a JSON
array, and if parsing fails, retry once with a short "your output was not
valid JSON, fix it" repair message before giving up.

Unit tests use `FakeLLM`-style stand-ins / a fake `requests.Session`; no
live network calls happen in the test suite.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Any, Protocol

import requests

from insights.config import Config

logger = logging.getLogger(__name__)


class LLMError(RuntimeError):
    """Raised when the LLM endpoint fails or returns something unusable."""


class ChatClient(Protocol):
    """Minimal interface `extract`/`verify` depend on — easy to fake in tests."""

    def chat(self, system_prompt: str, user_prompt: str) -> str:
        """Return the raw text content of the model's reply."""
        ...

    def chat_json_array(self, system_prompt: str, user_prompt: str) -> list[Any]:
        """Return the model's reply parsed as a JSON array, with one repair retry."""
        ...


_REPAIR_INSTRUCTION = (
    "Your previous output could not be parsed as a single JSON array. "
    "Output ONLY a valid JSON array (starting with `[` and ending with `]`), "
    "with no markdown code fences and no prose before or after it. "
    "Here is your previous output to fix:\n\n{prior}"
)


def extract_json_array(text: str) -> list[Any] | None:
    """Best-effort extraction of a JSON array from a model reply.

    Handles the common failure modes: markdown code fences, leading/trailing
    prose, or the array being the only thing surrounded by whitespace.
    Returns None if no JSON array could be parsed.
    """
    stripped = text.strip()

    # Strip a ```json ... ``` or ``` ... ``` fence if present.
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        if lines:
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        stripped = "\n".join(lines).strip()

    # Direct parse first.
    try:
        parsed = json.loads(stripped)
        if isinstance(parsed, list):
            return parsed
        return None
    except json.JSONDecodeError:
        pass

    # Fall back to slicing between the first `[` and the last `]`.
    start = stripped.find("[")
    end = stripped.rfind("]")
    if start == -1 or end == -1 or end < start:
        return None
    candidate = stripped[start : end + 1]
    try:
        parsed = json.loads(candidate)
        if isinstance(parsed, list):
            return parsed
    except json.JSONDecodeError:
        return None
    return None


@dataclass(slots=True)
class OllamaChatClient:
    """`ChatClient` backed by an OpenAI-compatible `/chat/completions` endpoint."""

    config: Config
    session: requests.Session | None = None

    def _post(self, messages: list[dict[str, str]]) -> str:
        session = self.session or requests
        url = f"{self.config.llm_base_url}/chat/completions"
        payload = {
            "model": self.config.llm_model,
            "messages": messages,
            "stream": False,
        }
        last_err: Exception | None = None
        for attempt in range(self.config.llm_max_retries + 1):
            try:
                resp = session.post(
                    url, json=payload, timeout=self.config.llm_timeout_secs
                )
                resp.raise_for_status()
                data = resp.json()
                return data["choices"][0]["message"]["content"]
            except (requests.RequestException, KeyError, IndexError, ValueError) as exc:
                last_err = exc
                logger.warning(
                    "LLM call failed (attempt %d/%d): %s",
                    attempt + 1,
                    self.config.llm_max_retries + 1,
                    exc,
                )
        raise LLMError(f"LLM call to {url} failed after retries: {last_err}") from last_err

    def chat(self, system_prompt: str, user_prompt: str) -> str:
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ]
        return self._post(messages)

    def chat_json_array(self, system_prompt: str, user_prompt: str) -> list[Any]:
        content = self.chat(system_prompt, user_prompt)
        parsed = extract_json_array(content)
        if parsed is not None:
            return parsed

        logger.warning("Model reply was not a JSON array; attempting one repair retry.")
        repair_messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
            {"role": "assistant", "content": content},
            {
                "role": "user",
                "content": _REPAIR_INSTRUCTION.format(prior=content[:2000]),
            },
        ]
        repaired = self._post(repair_messages)
        parsed = extract_json_array(repaired)
        if parsed is not None:
            return parsed

        raise LLMError(
            "Model reply could not be parsed as a JSON array even after a repair retry."
        )
