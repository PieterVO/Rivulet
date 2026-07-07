"""Stage 1: seed — build the work list.

TMDB popular + trending (movies & TV), intersected with a Plex library dump
(so we only generate trivia for things actually in the user's library),
plus a re-curation priority list (titles with queued reports; P2b feeds
this — for P2a it's an optional, usually-empty file) which always goes in
ahead of freshly-discovered titles.

Pure core: `build_seed_list()` takes already-fetched TMDB candidate lists +
an already-fetched Plex library index + an already-loaded re-curation list,
and returns the ordered, deduped work list. No network or disk IO in the
core — that's easy to unit test with fixture inputs.

Thin IO shell: `run()` fetches TMDB lists via the existing tmdb-proxy
Worker, dumps the Plex library via the Plex API (same box in prod), reads
the re-curation file if present, and writes `seed.jsonl` to the data dir.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Literal

import requests

from insights.config import Config

logger = logging.getLogger(__name__)

MediaType = Literal["movie", "tv"]

# TMDB list sections pulled from tmdb-proxy for seeding (see tmdb-proxy's
# LIST_SECTIONS; we only use these two — "popular" for library relevance and
# "trending" for what's topical right now).
TMDB_LIST_SECTIONS: tuple[str, ...] = ("popular", "trending")


@dataclass(slots=True, frozen=True)
class WorkItem:
    """One title (or episode) to run through discover->publish."""

    tmdb_id: int
    type: MediaType
    title: str
    year: int | None
    # Episode-only fields; None for movies and show-level TV work items.
    season: int | None = None
    episode: int | None = None
    # Why this item made the list: "recurate" | "popular" | "trending".
    reason: str = "popular"

    @property
    def key(self) -> str:
        """Dedup/identity key — same title+season+episode is the same work item."""
        if self.season is not None and self.episode is not None:
            return f"{self.type}:{self.tmdb_id}:S{self.season}E{self.episode}"
        return f"{self.type}:{self.tmdb_id}"

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "WorkItem":
        return cls(
            tmdb_id=int(d["tmdb_id"]),
            type=d["type"],
            title=d["title"],
            year=d.get("year"),
            season=d.get("season"),
            episode=d.get("episode"),
            reason=d.get("reason", "popular"),
        )


def build_seed_list(
    recurate_items: list[WorkItem],
    tmdb_candidates: list[WorkItem],
    plex_library_tmdb_ids: set[tuple[MediaType, int]],
) -> list[WorkItem]:
    """Pure core: merge re-curation + TMDB-candidates-that-are-in-the-library.

    Ordering: re-curation items first (already deduped against each other),
    then TMDB candidates in the order given (callers pass popular before
    trending, and within a section TMDB's own popularity order), filtered to
    only those present in the Plex library dump. Dedup by `WorkItem.key`;
    first occurrence wins (so a recurate entry beats a rediscovered
    duplicate, and "popular" beats "trending" if the same title is both).
    """
    seen: set[str] = set()
    result: list[WorkItem] = []

    for item in recurate_items:
        if item.key in seen:
            continue
        seen.add(item.key)
        result.append(item)

    for item in tmdb_candidates:
        if item.key in seen:
            continue
        if (item.type, item.tmdb_id) not in plex_library_tmdb_ids:
            continue
        seen.add(item.key)
        result.append(item)

    return result


def parse_tmdb_list_response(
    payload: dict[str, Any], media_type: MediaType, reason: str
) -> list[WorkItem]:
    """Turn a TMDB `/tmdb/list/{section}` response into WorkItems.

    Pure: takes an already-decoded JSON dict, no network. Skips entries
    missing an id or title/name (defensive — TMDB list payloads are usually
    clean, but seed must never crash a whole batch on one bad entry).
    """
    items: list[WorkItem] = []
    for entry in payload.get("results", []):
        tmdb_id = entry.get("id")
        title = entry.get("title") if media_type == "movie" else entry.get("name")
        if tmdb_id is None or not title:
            continue
        date_field = "release_date" if media_type == "movie" else "first_air_date"
        year = _year_from_date(entry.get(date_field))
        items.append(
            WorkItem(tmdb_id=int(tmdb_id), type=media_type, title=title, year=year, reason=reason)
        )
    return items


def _year_from_date(date_str: str | None) -> int | None:
    if not date_str or len(date_str) < 4:
        return None
    try:
        return int(date_str[:4])
    except ValueError:
        return None


def parse_plex_library_response(payload: dict[str, Any]) -> set[tuple[MediaType, int]]:
    """Extract `(type, tmdb_id)` pairs from a Plex `/library/sections/{id}/all` dump.

    Expects `includeGuids=1` responses: each `Metadata` entry carries a
    `Guid` array with entries like `{"id": "tmdb://27205"}`. `type` on the
    Plex entry is `"movie"` or `"show"`; we map `"show"` -> `"tv"` to match
    TMDB's media-type vocabulary.
    """
    result: set[tuple[MediaType, int]] = set()
    metadata_list = payload.get("MediaContainer", {}).get("Metadata", [])
    for entry in metadata_list:
        plex_type = entry.get("type")
        if plex_type == "movie":
            media_type: MediaType = "movie"
        elif plex_type == "show":
            media_type = "tv"
        else:
            continue
        for guid_entry in entry.get("Guid", []) or []:
            guid = guid_entry.get("id", "")
            if guid.startswith("tmdb://"):
                try:
                    tmdb_id = int(guid.removeprefix("tmdb://"))
                except ValueError:
                    continue
                result.add((media_type, tmdb_id))
    return result


def load_recurate_list(path: Path) -> list[WorkItem]:
    """Read the optional re-curation priority list (one JSON object per line).

    Missing file -> empty list (P2a default; P2b's report-drain writes it).
    """
    if not path.exists():
        return []
    items: list[WorkItem] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            items.append(WorkItem.from_dict({**d, "reason": "recurate"}))
    return items


def write_seed_jsonl(items: list[WorkItem], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for item in items:
            f.write(json.dumps(item.to_dict()) + "\n")


def load_seed_jsonl(path: Path) -> list[WorkItem]:
    """Read seed.jsonl back — used by downstream stages (discover, publish)
    that need the full WorkItem (title/year/season/episode), not just facts.
    """
    if not path.exists():
        return []
    items: list[WorkItem] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                items.append(WorkItem.from_dict(json.loads(line)))
    return items


def _fetch_tmdb_list(config: Config, section: str, media_type: MediaType) -> dict[str, Any]:
    url = f"{config.tmdb_proxy_base_url}/tmdb/list/{section}"
    resp = requests.get(url, params={"type": media_type}, timeout=30)
    resp.raise_for_status()
    return resp.json()


def _fetch_plex_library_dump(config: Config) -> dict[str, Any]:
    """Merge all movie/show sections into one Plex-shaped payload.

    Real Plex servers paginate per-section; for the seed intersection we
    only need `(type, tmdb_id)` pairs, so this walks every section and
    concatenates their `Metadata` arrays into a single container.
    """
    sections_url = f"{config.plex_base_url}/library/sections"
    headers = {"Accept": "application/json", "X-Plex-Token": config.plex_token}
    sections_resp = requests.get(sections_url, headers=headers, timeout=30)
    sections_resp.raise_for_status()
    sections = sections_resp.json().get("MediaContainer", {}).get("Directory", [])

    merged_metadata: list[dict[str, Any]] = []
    for section in sections:
        section_type = section.get("type")
        if section_type not in ("movie", "show"):
            continue
        section_id = section.get("key")
        items_url = f"{config.plex_base_url}/library/sections/{section_id}/all"
        resp = requests.get(
            items_url,
            headers=headers,
            params={"includeGuids": "1"},
            timeout=60,
        )
        resp.raise_for_status()
        merged_metadata.extend(resp.json().get("MediaContainer", {}).get("Metadata", []))

    return {"MediaContainer": {"Metadata": merged_metadata}}


def run(config: Config) -> list[WorkItem]:
    """IO shell: fetch TMDB lists + Plex library + re-curation file, build+write seed.jsonl."""
    recurate_items = load_recurate_list(config.data_dir / "recurate.jsonl")

    tmdb_candidates: list[WorkItem] = []
    for section in TMDB_LIST_SECTIONS:
        for media_type in ("movie", "tv"):
            try:
                payload = _fetch_tmdb_list(config, section, media_type)  # type: ignore[arg-type]
            except requests.RequestException as exc:
                logger.warning("TMDB list fetch failed (%s/%s): %s", section, media_type, exc)
                continue
            tmdb_candidates.extend(
                parse_tmdb_list_response(payload, media_type, reason=section)  # type: ignore[arg-type]
            )

    try:
        plex_payload = _fetch_plex_library_dump(config)
        plex_ids = parse_plex_library_response(plex_payload)
    except requests.RequestException as exc:
        logger.error("Plex library dump failed: %s", exc)
        plex_ids = set()

    seed_list = build_seed_list(recurate_items, tmdb_candidates, plex_ids)
    logger.info(
        "seed: %d recurate + %d tmdb-candidates -> %d in-library work items",
        len(recurate_items),
        len(tmdb_candidates),
        len(seed_list),
    )
    write_seed_jsonl(seed_list, config.data_dir / "seed.jsonl")
    return seed_list
