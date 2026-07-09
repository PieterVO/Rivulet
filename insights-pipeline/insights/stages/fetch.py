"""Stage 3: fetch — pull page content from Wikipedia + Fandom.

Uses the MediaWiki Action API (`action=parse`, `prop=wikitext|sections`) for
both hosts — Wikipedia and whatever Fandom wiki `discover` resolved. Pulls
the full wikitext once per page, cached on disk (keyed by URL) so re-runs
never re-fetch a page already on disk — polite rate limiting lives in the
IO shell, not in the cache-hit path.

Section-aware: extracts only the sections useful for trivia (Production,
Casting, Development, Reception, Trivia, Continuity, and their common
variants) and skips navboxes/infobox dumps/reference lists, which is
everything MediaWiki's `sections` listing wouldn't already exclude for us
(wikitext markup like `{{Infobox ...}}` and `<ref>...</ref>` blocks).

Pure core: `select_sections` (which of a page's sections to keep) and
`extract_section_text` / `strip_wiki_markup` (turning a section's raw
wikitext into prose-ish text for extract) are unit tested against fixture
wikitext, no network involved.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests

from insights.config import Config
from insights.stages.discover import SourceMapEntry

logger = logging.getLogger(__name__)

# Section headings we keep (case-insensitive substring match against the
# heading's own text). Deliberately broad — Wikipedia/Fandom section naming
# varies a lot across pages ("Casting" vs "Cast", "Production" vs
# "Filming", etc.) — over-inclusion here is fine, extract's grounding rule
# throws out anything that isn't actually a fact.
WANTED_SECTION_KEYWORDS: tuple[str, ...] = (
    "production",
    "casting",
    "cast",
    "development",
    "filming",
    "writing",
    "reception",
    "trivia",
    "continuity",
    "goofs",
    "music",
    "soundtrack",
    "adaptation",
    "background",
)

# Sections we explicitly never want even if a keyword above would match a
# substring of them (e.g. "External links" containing no wanted keyword
# already excludes itself, but be explicit for common non-prose sections).
EXCLUDED_SECTION_KEYWORDS: tuple[str, ...] = (
    "references",
    "external links",
    "see also",
    "navigation",
    "notes",
    "further reading",
    "gallery",
)

_HEADING_RE = re.compile(r"^(={2,6})\s*(.+?)\s*\1\s*$", re.MULTILINE)
_REF_RE = re.compile(r"<ref[^>]*>.*?</ref>|<ref[^>]*/>", re.DOTALL | re.IGNORECASE)
_TEMPLATE_RE = re.compile(r"\{\{[^{}]*\}\}")
_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)
_WIKILINK_RE = re.compile(r"\[\[(?:[^|\]]*\|)?([^\]]+)\]\]")
_EXTLINK_RE = re.compile(r"\[(?:https?://\S+)\s+([^\]]+)\]")
_BOLD_ITALIC_RE = re.compile(r"'''''|'''|''")
_HTML_TAG_RE = re.compile(r"<[^>]+>")


@dataclass(slots=True, frozen=True)
class WikiSection:
    heading: str
    level: int
    body: str


@dataclass(slots=True, frozen=True)
class FetchedPage:
    url: str
    title: str
    sections: list[WikiSection]


def is_wanted_section(heading: str) -> bool:
    """Pure: should this section heading's body be kept for extraction?"""
    lower = heading.lower()
    if any(bad in lower for bad in EXCLUDED_SECTION_KEYWORDS):
        return False
    return any(good in lower for good in WANTED_SECTION_KEYWORDS)


def parse_wikitext_sections(wikitext: str, page_title: str) -> list[WikiSection]:
    """Split raw wikitext into (heading, level, body) sections.

    Content before the first heading is treated as an implicit lead section
    titled with the page's own title (Wikipedia/Fandom ledes are often
    genuinely useful, plot-adjacent prose lives further down under actual
    headings so the lead is safe to include generically).
    """
    matches = list(_HEADING_RE.finditer(wikitext))
    sections: list[WikiSection] = []

    lead_end = matches[0].start() if matches else len(wikitext)
    lead_body = wikitext[:lead_end].strip()
    if lead_body:
        sections.append(WikiSection(heading=page_title, level=1, body=lead_body))

    for i, m in enumerate(matches):
        heading = m.group(2).strip()
        level = len(m.group(1))
        body_start = m.end()
        body_end = matches[i + 1].start() if i + 1 < len(matches) else len(wikitext)
        body = wikitext[body_start:body_end].strip()
        sections.append(WikiSection(heading=heading, level=level, body=body))

    return sections


def select_sections(sections: list[WikiSection]) -> list[WikiSection]:
    """Pure: filter a page's sections down to the ones worth extracting from."""
    return [s for s in sections if is_wanted_section(s.heading) and s.body]


def strip_wiki_markup(text: str) -> str:
    """Pure: turn a section's raw wikitext into plain-ish prose for the LLM.

    Removes `<ref>` citations, `{{templates}}`, HTML comments, and
    unwraps `[[wikilink|label]]` / `[url label]` down to their display
    text, and strips bold/italic markup + stray HTML tags. Not a full
    wikitext parser — good enough for extraction, which only needs
    readable prose, not perfect rendering.
    """
    result = _REF_RE.sub("", text)
    result = _COMMENT_RE.sub("", result)
    # Templates can nest; run a few passes to unwind common single-level nesting.
    for _ in range(3):
        result = _TEMPLATE_RE.sub("", result)
    result = _WIKILINK_RE.sub(r"\1", result)
    result = _EXTLINK_RE.sub(r"\1", result)
    result = _BOLD_ITALIC_RE.sub("", result)
    result = _HTML_TAG_RE.sub("", result)
    # Collapse excess blank lines left behind by stripped templates/refs.
    result = re.sub(r"\n{3,}", "\n\n", result)
    return result.strip()


def cache_key_for_url(url: str) -> str:
    """Pure: stable on-disk cache filename for a page URL."""
    return hashlib.sha1(url.encode("utf-8")).hexdigest() + ".wikitext"


def _mediawiki_api_base(url: str) -> tuple[str, str]:
    """Derive (api_base_url, page_title) from an article URL.

    Handles both Wikipedia (`en.wikipedia.org/wiki/Title`) and Fandom
    (`{wiki}.fandom.com/wiki/Title`) URL shapes — both are MediaWiki, the
    API endpoint is always `.../w/api.php` (Wikipedia) or `.../api.php`
    (Fandom serves it at the wiki root).
    """
    if "wikipedia.org" in url:
        host = url.split("/wiki/")[0]
        api_base = f"{host}/w/api.php"
    else:
        host = url.split("/wiki/")[0]
        api_base = f"{host}/api.php"
    title = url.split("/wiki/")[-1].replace("_", " ")
    import urllib.parse

    title = urllib.parse.unquote(title)
    return api_base, title


def _fetch_wikitext(url: str, *, rate_limit_secs: float = 0.5) -> str | None:
    api_base, title = _mediawiki_api_base(url)
    try:
        resp = requests.get(
            api_base,
            params={
                "action": "parse",
                "page": title,
                "prop": "wikitext",
                "format": "json",
                "redirects": "1",
            },
            headers={"User-Agent": "RivuletInsightsPipeline/1.0 (offline trivia fetch)"},
            timeout=30,
        )
        resp.raise_for_status()
        data = resp.json()
        if "error" in data:
            logger.warning("MediaWiki parse error for %s: %s", url, data["error"])
            return None
        wikitext = data.get("parse", {}).get("wikitext", {})
        if isinstance(wikitext, dict):
            return wikitext.get("*")
        return wikitext
    except requests.RequestException as exc:
        logger.warning("Fetch failed for %s: %s", url, exc)
        return None
    finally:
        time.sleep(rate_limit_secs)


def fetch_page_cached(url: str, cache_dir: Path, *, rate_limit_secs: float = 0.5) -> FetchedPage | None:
    """Fetch a page's wikitext (disk-cached by URL hash), split+filter sections.

    Only a successful fetch is written to the cache. A failure (network
    error, MediaWiki error, empty page) is NEVER cached — caching an empty
    result would make a transient failure permanent, since the cache-hit
    check is just "does the file exist," and every future re-run of this
    resumable stage would treat that as a confirmed "no content" instead of
    retrying.
    """
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / cache_key_for_url(url)

    if cache_path.exists():
        wikitext = cache_path.read_text(encoding="utf-8")
    else:
        wikitext = _fetch_wikitext(url, rate_limit_secs=rate_limit_secs)
        if not wikitext:
            return None
        cache_path.write_text(wikitext, encoding="utf-8")

    _, title = _mediawiki_api_base(url)
    all_sections = parse_wikitext_sections(wikitext, title)
    wanted = select_sections(all_sections)
    cleaned = [WikiSection(s.heading, s.level, strip_wiki_markup(s.body)) for s in wanted]
    cleaned = [s for s in cleaned if s.body]
    return FetchedPage(url=url, title=title, sections=cleaned)


def _page_to_dict(page: FetchedPage) -> dict[str, Any]:
    return {
        "url": page.url,
        "title": page.title,
        "sections": [{"heading": s.heading, "level": s.level, "body": s.body} for s in page.sections],
    }


def _page_from_dict(d: dict[str, Any]) -> FetchedPage:
    return FetchedPage(
        url=d["url"],
        title=d["title"],
        sections=[WikiSection(s["heading"], s["level"], s["body"]) for s in d["sections"]],
    )


def write_fetched_pages_jsonl(pages_by_key: dict[str, list[FetchedPage]], path: Path) -> None:
    """Persist fetch's output so extract (and the CLI, run stage-by-stage) can
    resume without re-fetching — the section-filtered/cleaned text, not just
    the raw wikitext cache, so extract never re-does the cleanup pass either.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for key, pages in pages_by_key.items():
            f.write(json.dumps({"key": key, "pages": [_page_to_dict(p) for p in pages]}) + "\n")


def load_fetched_pages_jsonl(path: Path) -> dict[str, list[FetchedPage]]:
    if not path.exists():
        return {}
    result: dict[str, list[FetchedPage]] = {}
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            result[d["key"]] = [_page_from_dict(pd) for pd in d["pages"]]
    return result


def run(config: Config) -> dict[str, list[FetchedPage]]:
    """IO shell: for every resolved sourcemap entry, fetch + cache + section-filter both pages."""
    from insights.stages.discover import load_sourcemap_jsonl

    sourcemap_path = config.data_dir / "sourcemap.jsonl"
    cache_dir = config.data_dir / "page_cache"
    fetched_pages_path = config.data_dir / "fetched_pages.jsonl"

    entries: dict[str, SourceMapEntry] = load_sourcemap_jsonl(sourcemap_path)
    already_fetched = load_fetched_pages_jsonl(fetched_pages_path)
    result: dict[str, list[FetchedPage]] = dict(already_fetched)

    for key, entry in entries.items():
        if key in already_fetched:
            continue
        pages: list[FetchedPage] = []
        if entry.wikipedia_url:
            page = fetch_page_cached(entry.wikipedia_url, cache_dir)
            if page:
                pages.append(page)
        if entry.fandom_page_url:
            page = fetch_page_cached(entry.fandom_page_url, cache_dir)
            if page:
                pages.append(page)
        if pages:
            result[key] = pages
        else:
            logger.info("fetch: no usable sections for %s", key)

    write_fetched_pages_jsonl(result, fetched_pages_path)
    logger.info("fetch: %d/%d work items produced usable sections", len(result), len(entries))
    return result
