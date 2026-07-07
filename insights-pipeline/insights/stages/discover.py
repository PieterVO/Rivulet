"""Stage 2: discover — locate Wikipedia + Fandom sources for each work item.

Per work item, resolve:
- a Wikipedia article (Wikipedia's `opensearch`/`query` API, title+year+type
  heuristics to rank candidates), and
- a Fandom wiki + specific page (Fandom's search API; episode pages for TV).

Because titles are ambiguous ("Silo" the TV show vs. any number of other
things), a local-LLM adjudication call confirms the top candidate before we
commit to it ("Is this page about *Inception* (2010 film)? yes/no"). No
match / an adjudication "no" -> logged and skipped, never guessed.

Pure core: candidate ranking (`rank_candidates`) and the decision of what to
do with the ranked list + adjudication answers (`decide_source`) are pure
functions over already-fetched search results, easy to unit test. The IO
shell (`run`) does the actual Wikipedia/Fandom HTTP calls + LLM adjudication
and writes `sourcemap.jsonl`.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import requests

from insights.config import Config
from insights.llm import ChatClient, OllamaChatClient
from insights.stages.seed import WorkItem, load_seed_jsonl

logger = logging.getLogger(__name__)

WIKIPEDIA_API = "https://en.wikipedia.org/w/api.php"
FANDOM_SEARCH_TEMPLATE = "https://{wiki}.fandom.com/api.php"

ADJUDICATION_SYSTEM_PROMPT = (
    "You are confirming whether an encyclopedia page is about a specific film or TV "
    "show. Answer with exactly one word: yes or no. Do not explain your reasoning."
)


@dataclass(slots=True, frozen=True)
class SourceCandidate:
    """One ranked candidate page for a work item, before adjudication."""

    title: str
    url: str
    snippet: str = ""


@dataclass(slots=True, frozen=True)
class SourceMapEntry:
    """Resolved sources for one work item. Any field may be None (not found)."""

    key: str  # WorkItem.key
    wikipedia_url: str | None
    fandom_wiki: str | None
    fandom_page_url: str | None
    status: str  # "resolved" | "no_match" | "ambiguous"

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "SourceMapEntry":
        return cls(
            key=d["key"],
            wikipedia_url=d.get("wikipedia_url"),
            fandom_wiki=d.get("fandom_wiki"),
            fandom_page_url=d.get("fandom_page_url"),
            status=d["status"],
        )


_YEAR_RE = re.compile(r"\((\d{4})")
_DISAMBIG_MARKERS = ("disambiguation", "may refer to")


def rank_candidates(
    candidates: list[SourceCandidate], work_item: WorkItem
) -> list[SourceCandidate]:
    """Pure ranking: title+year+type heuristics, best candidate first.

    Scoring (higher is better):
    - exact case-insensitive title match: +3
    - candidate title contains the work item's year (in parens, Wikipedia's
      disambiguation convention e.g. "Silo (TV series)"): +2
    - candidate title contains a type hint matching the work item
      ("film"/"TV series"/"TV show" etc.): +1
    - disambiguation pages are demoted heavily (they're not the actual
      article; adjudication would just waste a call): -5
    Ties keep the original (search-engine) order — stable sort.
    """

    def score(c: SourceCandidate) -> int:
        s = 0
        title_lower = c.title.lower()
        snippet_lower = c.snippet.lower()
        if title_lower == work_item.title.lower():
            s += 3
        if work_item.year is not None:
            match = _YEAR_RE.search(c.title)
            if match and int(match.group(1)) == work_item.year:
                s += 2
        type_hints = ("film", "movie") if work_item.type == "movie" else ("tv series", "tv show")
        if any(hint in title_lower for hint in type_hints):
            s += 1
        if any(marker in title_lower or marker in snippet_lower for marker in _DISAMBIG_MARKERS):
            s -= 5
        return s

    return sorted(candidates, key=score, reverse=True)


def decide_source(
    ranked_wikipedia: list[SourceCandidate],
    ranked_fandom: list[SourceCandidate],
    wikipedia_confirmed: bool,
    fandom_confirmed: bool,
) -> tuple[str | None, str | None]:
    """Pure decision: given ranked candidates + adjudication answers for the
    top candidate of each, return (wikipedia_url, fandom_page_url) — either
    may be None. Never falls back to an unconfirmed candidate.
    """
    wikipedia_url = None
    if ranked_wikipedia and wikipedia_confirmed:
        wikipedia_url = ranked_wikipedia[0].url

    fandom_page_url = None
    if ranked_fandom and fandom_confirmed:
        fandom_page_url = ranked_fandom[0].url

    return wikipedia_url, fandom_page_url


def status_for(wikipedia_url: str | None, fandom_page_url: str | None, had_candidates: bool) -> str:
    """Pure: classify the outcome for logging/reporting."""
    if wikipedia_url or fandom_page_url:
        return "resolved"
    if had_candidates:
        return "ambiguous"
    return "no_match"


def adjudication_prompt(work_item: WorkItem, candidate: SourceCandidate) -> str:
    year_str = f" ({work_item.year})" if work_item.year else ""
    kind = "film" if work_item.type == "movie" else "TV show"
    episode_str = ""
    if work_item.season is not None and work_item.episode is not None:
        episode_str = f", specifically season {work_item.season} episode {work_item.episode}"
    return (
        f'Page title: "{candidate.title}"\n'
        f"Page snippet: {candidate.snippet or '(no snippet available)'}\n\n"
        f'Is this page about the {kind} "{work_item.title}"{year_str}{episode_str}? '
        "Answer yes or no."
    )


def parse_adjudication_answer(reply: str) -> bool:
    """Pure: 'yes'/'no' (possibly with punctuation/whitespace) -> bool. Defaults
    to False (not confirmed) on anything ambiguous — never guess a source.
    """
    normalized = reply.strip().lower().strip(".! ")
    return normalized.startswith("yes")


def parse_wikipedia_opensearch(payload: list[Any]) -> list[SourceCandidate]:
    """Wikipedia `action=opensearch` returns `[query, [titles], [descriptions], [urls]]`."""
    if not isinstance(payload, list) or len(payload) < 4:
        return []
    titles, descriptions, urls = payload[1], payload[2], payload[3]
    candidates = []
    for title, desc, url in zip(titles, descriptions, urls):
        candidates.append(SourceCandidate(title=title, url=url, snippet=desc or ""))
    return candidates


def parse_fandom_search(payload: dict[str, Any], wiki: str) -> list[SourceCandidate]:
    """Fandom's MediaWiki `list=search` response -> candidates with page URLs."""
    results = payload.get("query", {}).get("search", [])
    candidates = []
    for entry in results:
        title = entry.get("title", "")
        snippet = re.sub(r"<[^>]+>", "", entry.get("snippet", ""))
        url = f"https://{wiki}.fandom.com/wiki/{title.replace(' ', '_')}"
        candidates.append(SourceCandidate(title=title, url=url, snippet=snippet))
    return candidates


def _fetch_wikipedia_candidates(work_item: WorkItem) -> list[SourceCandidate]:
    resp = requests.get(
        WIKIPEDIA_API,
        params={
            "action": "opensearch",
            "search": work_item.title,
            "limit": "5",
            "namespace": "0",
            "format": "json",
        },
        timeout=30,
    )
    resp.raise_for_status()
    return parse_wikipedia_opensearch(resp.json())


def _guess_fandom_wiki_slug(work_item: WorkItem) -> str:
    slug = re.sub(r"[^a-z0-9]+", "", work_item.title.lower())
    return slug or "unknown"


def _fetch_fandom_candidates(work_item: WorkItem) -> tuple[str, list[SourceCandidate]]:
    wiki = _guess_fandom_wiki_slug(work_item)
    url = FANDOM_SEARCH_TEMPLATE.format(wiki=wiki)
    query = work_item.title
    if work_item.season is not None and work_item.episode is not None:
        query = f"{work_item.title} season {work_item.season} episode {work_item.episode}"
    resp = requests.get(
        url,
        params={
            "action": "query",
            "list": "search",
            "srsearch": query,
            "srlimit": "5",
            "format": "json",
        },
        timeout=30,
    )
    resp.raise_for_status()
    return wiki, parse_fandom_search(resp.json(), wiki)


def resolve_one(
    work_item: WorkItem, chat_client: ChatClient, *, fetch_wikipedia: bool = True, fetch_fandom: bool = True
) -> SourceMapEntry:
    """Resolve sources for a single work item (network + LLM adjudication)."""
    ranked_wikipedia: list[SourceCandidate] = []
    ranked_fandom: list[SourceCandidate] = []
    had_candidates = False

    if fetch_wikipedia:
        try:
            wiki_candidates = _fetch_wikipedia_candidates(work_item)
            ranked_wikipedia = rank_candidates(wiki_candidates, work_item)
            had_candidates = had_candidates or bool(wiki_candidates)
        except requests.RequestException as exc:
            logger.warning("Wikipedia search failed for %s: %s", work_item.key, exc)

    fandom_wiki_slug: str | None = None
    if fetch_fandom:
        try:
            fandom_wiki_slug, fandom_candidates = _fetch_fandom_candidates(work_item)
            ranked_fandom = rank_candidates(fandom_candidates, work_item)
            had_candidates = had_candidates or bool(fandom_candidates)
        except requests.RequestException as exc:
            logger.warning("Fandom search failed for %s: %s", work_item.key, exc)

    wikipedia_confirmed = False
    if ranked_wikipedia:
        try:
            reply = chat_client.chat(
                ADJUDICATION_SYSTEM_PROMPT, adjudication_prompt(work_item, ranked_wikipedia[0])
            )
            wikipedia_confirmed = parse_adjudication_answer(reply)
        except Exception as exc:  # noqa: BLE001 - adjudication failure -> treat as unconfirmed
            logger.warning("Wikipedia adjudication failed for %s: %s", work_item.key, exc)

    fandom_confirmed = False
    if ranked_fandom:
        try:
            reply = chat_client.chat(
                ADJUDICATION_SYSTEM_PROMPT, adjudication_prompt(work_item, ranked_fandom[0])
            )
            fandom_confirmed = parse_adjudication_answer(reply)
        except Exception as exc:  # noqa: BLE001
            logger.warning("Fandom adjudication failed for %s: %s", work_item.key, exc)

    wikipedia_url, fandom_page_url = decide_source(
        ranked_wikipedia, ranked_fandom, wikipedia_confirmed, fandom_confirmed
    )
    status = status_for(wikipedia_url, fandom_page_url, had_candidates)

    return SourceMapEntry(
        key=work_item.key,
        wikipedia_url=wikipedia_url,
        fandom_wiki=fandom_wiki_slug if fandom_page_url else None,
        fandom_page_url=fandom_page_url,
        status=status,
    )


def write_sourcemap_jsonl(entries: list[SourceMapEntry], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for entry in entries:
            f.write(json.dumps(entry.to_dict()) + "\n")


def load_sourcemap_jsonl(path: Path) -> dict[str, SourceMapEntry]:
    """Keyed by WorkItem.key, for resumability (skip already-resolved items)."""
    if not path.exists():
        return {}
    result: dict[str, SourceMapEntry] = {}
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                entry = SourceMapEntry.from_dict(json.loads(line))
                result[entry.key] = entry
    return result


def run(config: Config) -> list[SourceMapEntry]:
    """IO shell: resolve sources for every item in seed.jsonl not already in sourcemap.jsonl."""
    seed_path = config.data_dir / "seed.jsonl"
    sourcemap_path = config.data_dir / "sourcemap.jsonl"

    work_items = load_seed_jsonl(seed_path)
    already_resolved = load_sourcemap_jsonl(sourcemap_path)

    chat_client = OllamaChatClient(config=config)
    entries = list(already_resolved.values())

    resolved_count = 0
    skipped_count = 0
    for item in work_items:
        if item.key in already_resolved:
            continue
        entry = resolve_one(item, chat_client)
        entries.append(entry)
        if entry.status == "resolved":
            resolved_count += 1
        else:
            skipped_count += 1
            logger.info("discover: %s -> %s (no source committed)", item.key, entry.status)

    write_sourcemap_jsonl(entries, sourcemap_path)
    logger.info(
        "discover: %d resolved, %d skipped (no_match/ambiguous), %d already cached",
        resolved_count,
        skipped_count,
        len(already_resolved),
    )
    return entries
