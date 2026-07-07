"""Schema dataclasses for the Insights trivia pipeline.

These mirror the published JSON consumed by the tvOS client
(`Rivulet/Models/Insights/TriviaFact.swift`) and the design spec
`Docs/superpowers/specs/2026-07-07-insights-trivia-pipeline-design.md`.

The published payload strips `source_snippet` (kept only through the verify
stage); `to_published_dict` produces the client-facing shape.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Any, Literal

Category = Literal[
    "production", "casting", "adaptation", "reference", "lore", "goof", "music"
]
CATEGORIES: frozenset[str] = frozenset(
    ("production", "casting", "adaptation", "reference", "lore", "goof", "music")
)
# Spoiler levels: 0 none · 1 this title's plot · 2 later episodes/seasons.
SPOILER_LEVELS: frozenset[int] = frozenset((0, 1, 2))


def fact_id(text: str, source_url: str) -> str:
    """Stable id for a fact = short hash of text + source url.

    Stable across re-publishes of a title so reports and the suppression
    list survive re-curation. Normalizes surrounding whitespace so a
    re-extract with cosmetic spacing differences keeps the same id.
    """
    basis = f"{text.strip()}\x00{source_url.strip()}".encode("utf-8")
    return "f_" + hashlib.sha1(basis).hexdigest()[:12]


@dataclass(slots=True)
class Source:
    name: str
    url: str

    def to_dict(self) -> dict[str, str]:
        return {"name": self.name, "url": self.url}

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Source":
        return cls(name=d["name"], url=d["url"])


@dataclass(slots=True)
class Fact:
    text: str
    category: str
    spoiler: int
    source: Source
    # Retained only through verify; NOT published. The exact source
    # sentence(s) the fact was extracted from, for the verify re-check.
    source_snippet: str = ""

    @property
    def id(self) -> str:
        return fact_id(self.text, self.source.url)

    def is_valid(self) -> bool:
        return (
            bool(self.text.strip())
            and self.category in CATEGORIES
            and self.spoiler in SPOILER_LEVELS
            and bool(self.source.url.strip())
        )

    def to_published_dict(self) -> dict[str, Any]:
        """Client-facing shape — source_snippet stripped."""
        return {
            "id": self.id,
            "text": self.text,
            "category": self.category,
            "spoiler": self.spoiler,
            "source": self.source.to_dict(),
        }

    def to_working_dict(self) -> dict[str, Any]:
        """Full shape kept between stages (includes source_snippet)."""
        d = self.to_published_dict()
        d["source_snippet"] = self.source_snippet
        return d

    @classmethod
    def from_working_dict(cls, d: dict[str, Any]) -> "Fact":
        return cls(
            text=d["text"],
            category=d["category"],
            spoiler=int(d["spoiler"]),
            source=Source.from_dict(d["source"]),
            source_snippet=d.get("source_snippet", ""),
        )


@dataclass(slots=True)
class TitleTrivia:
    id: str  # e.g. "tmdb://27205"
    type: Literal["movie", "episode", "show"]
    generated_at: str  # ISO8601; stamped at publish (passed in, never Date.now here)
    pipeline_version: int
    attribution: list[Source] = field(default_factory=list)
    facts: list[Fact] = field(default_factory=list)

    def to_published_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "generatedAt": self.generated_at,
            "pipelineVersion": self.pipeline_version,
            "attribution": [s.to_dict() for s in self.attribution],
            "facts": [f.to_published_dict() for f in self.facts],
        }
