"""Stage 4: extract — Ollama, prose -> schema facts.

For each fetched page section, calls the extraction model (gemma4:31b-it-
q4_K_M per `bakeoff/DECISION.md`) with the bake-off's proven strict
extract-and-rewrite prompt (`bakeoff/prompts/extract_v1.txt`, reused as-is —
it's validated, not re-derived here) as the system prompt and the section's
cleaned text as the user message. One call per section (not per whole page)
so every returned fact can be paired with the exact section text it came
from as its `source_snippet` — the verify stage re-checks facts against
this snippet, so the snippet must be the precise text the model saw, not an
approximation.

The model emits `{text, category, spoiler, source}` per the prompt's schema
(`source` is a short section-label string, e.g. "Production" or the page's
own section heading). This stage maps that onto `models.Fact`: `source_snippet`
becomes the section's text, and `Source.name`/`Source.url` become the actual
page attribution (Wikipedia / the Fandom wiki's display name + the page URL)
— the model never sees or invents a URL.

Pure core: `raw_fact_to_fact` (schema mapping + defensive validation of a
single LLM-returned dict) and `attribution_source_for` (page URL -> Source)
are unit tested directly. `extract_section` / `run` are the thin IO shell
using a mocked `ChatClient` in tests — no live LLM calls.
"""

from __future__ import annotations

import logging
from pathlib import Path

from insights.config import Config
from insights.llm import ChatClient, LLMError, OllamaChatClient
from insights.models import CATEGORIES, SPOILER_LEVELS, Fact, Source
from insights.stages.fetch import FetchedPage, WikiSection

logger = logging.getLogger(__name__)

PROMPT_PATH = Path(__file__).resolve().parent.parent.parent / "bakeoff" / "prompts" / "extract_v1.txt"


def load_extract_prompt(path: Path = PROMPT_PATH) -> str:
    return path.read_text(encoding="utf-8")


def attribution_source_for(page: FetchedPage) -> Source:
    """Pure: derive the Source (name, url) attribution for facts from this page."""
    if "wikipedia.org" in page.url:
        return Source(name="Wikipedia", url=page.url)
    # Fandom: use the page's own title as a human-readable wiki name, e.g.
    # "https://silo.fandom.com/wiki/X" -> "Silo Wiki". Best-effort; falls
    # back to a generic label if the host can't be parsed.
    host = page.url.split("//")[-1].split(".")[0]
    wiki_name = f"{host.replace('-', ' ').title()} Wiki" if host else "Fandom"
    return Source(name=wiki_name, url=page.url)


def raw_fact_to_fact(raw: object, source: Source, source_snippet: str) -> Fact | None:
    """Pure: validate+map one LLM-returned dict to a Fact, or None if unusable.

    Defensive against the model not perfectly following the schema (missing
    field, wrong type, category/spoiler outside the enum, empty text) —
    extract stays permissive here (never crashes a batch on one bad
    entry); it's verify's job to be the strict gate.
    """
    if not isinstance(raw, dict):
        return None

    text = raw.get("text")
    if not isinstance(text, str) or not text.strip():
        return None

    category = raw.get("category")
    if category not in CATEGORIES:
        return None

    spoiler = raw.get("spoiler")
    if isinstance(spoiler, str) and spoiler.isdigit():
        spoiler = int(spoiler)
    if spoiler not in SPOILER_LEVELS:
        return None

    return Fact(
        text=text.strip(),
        category=category,
        spoiler=spoiler,
        source=source,
        source_snippet=source_snippet,
    )


def extract_section(
    chat_client: ChatClient,
    section: WikiSection,
    source: Source,
    system_prompt: str,
) -> list[Fact]:
    """Call the extraction model on one section's text; map replies to Facts.

    A call failure (LLMError) or a reply that isn't a JSON array of dicts
    logs a warning and yields zero facts for this section rather than
    aborting the whole run — one bad section shouldn't sink a title's batch.
    """
    try:
        raw_facts = chat_client.chat_json_array(system_prompt, section.body)
    except LLMError as exc:
        logger.warning("extract: LLM call failed for section %r: %s", section.heading, exc)
        return []

    facts: list[Fact] = []
    dropped = 0
    for raw in raw_facts:
        fact = raw_fact_to_fact(raw, source, source_snippet=section.body)
        if fact is None:
            dropped += 1
            continue
        facts.append(fact)

    if dropped:
        logger.info(
            "extract: section %r dropped %d/%d malformed entries",
            section.heading,
            dropped,
            len(raw_facts),
        )
    return facts


def extract_page(chat_client: ChatClient, page: FetchedPage, system_prompt: str) -> list[Fact]:
    """Extract facts from every kept section of one fetched page."""
    source = attribution_source_for(page)
    facts: list[Fact] = []
    for section in page.sections:
        facts.extend(extract_section(chat_client, section, source, system_prompt))
    return facts


def write_facts_raw_jsonl(facts_by_key: dict[str, list[Fact]], path: Path) -> None:
    import json

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for key, facts in facts_by_key.items():
            f.write(json.dumps({"key": key, "facts": [fact.to_working_dict() for fact in facts]}) + "\n")


def load_facts_raw_jsonl(path: Path) -> dict[str, list[Fact]]:
    import json

    if not path.exists():
        return {}
    result: dict[str, list[Fact]] = {}
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            result[d["key"]] = [Fact.from_working_dict(fd) for fd in d["facts"]]
    return result


def run(config: Config, pages_by_key: dict[str, list[FetchedPage]]) -> dict[str, list[Fact]]:
    """IO shell: extract facts for every work item's fetched pages, resumable via facts_raw.jsonl."""
    facts_raw_path = config.data_dir / "facts_raw.jsonl"
    already_extracted = load_facts_raw_jsonl(facts_raw_path)

    system_prompt = load_extract_prompt()
    chat_client = OllamaChatClient(config=config)

    result: dict[str, list[Fact]] = dict(already_extracted)
    for key, pages in pages_by_key.items():
        if key in already_extracted:
            continue
        facts: list[Fact] = []
        for page in pages:
            facts.extend(extract_page(chat_client, page, system_prompt))
        result[key] = facts
        logger.info("extract: %s -> %d raw facts", key, len(facts))

    write_facts_raw_jsonl(result, facts_raw_path)
    return result
