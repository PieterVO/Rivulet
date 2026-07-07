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

**Episode enumeration (P3 content freshness):** every TV show work item
from the merge above also gets its aired episodes enumerated via TMDB's
season endpoint (proxied by tmdb-proxy's `/tmdb/season/{id}?season=N`
route), producing one per-episode `WorkItem` per aired episode alongside
the show-level item. Freshness/idempotency is achieved by consulting the
`published.jsonl` manifest (appended to by the publish stage — see
`load_published_keys` / `append_published_keys`): episodes already
published are never re-enqueued, so a scheduled re-seed after new episodes
air only produces work items for what's actually new.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime
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
    # Why this item made the list: "recurate" | "popular" | "trending" | "episode"
    # ("episode" = enumerated from a tracked show's aired episode list, not
    # itself a TMDB popular/trending candidate).
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
    plex_library_tmdb_ids: set[tuple[MediaType, int]] | None,
) -> list[WorkItem]:
    """Pure core: merge re-curation + TMDB candidates.

    When `plex_library_tmdb_ids` is a set, TMDB candidates are filtered to only
    titles in that library (library-only mode). When it is `None`, ALL
    popular/trending TMDB candidates are kept (popular-only mode, the default)
    — no Plex needed. Re-curation items are always kept.

    Ordering: re-curation first (already deduped), then TMDB candidates in the
    order given (popular before trending, TMDB's popularity order within a
    section). Dedup by `WorkItem.key`; first occurrence wins.
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
        if plex_library_tmdb_ids is not None and (item.type, item.tmdb_id) not in plex_library_tmdb_ids:
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


# --- Episode enumeration (P3 content freshness) ---


def parse_tmdb_season_response(
    payload: dict[str, Any],
    *,
    tmdb_id: int,
    show_title: str,
    show_year: int | None,
    today: date,
) -> list[WorkItem]:
    """Pure: turn a TMDB `/tv/{id}/season/{n}` response into per-episode WorkItems.

    Only episodes that have already aired are included — an episode with no
    `air_date`, or an `air_date` in the future relative to `today`, is
    skipped (we don't generate trivia for episodes that haven't happened
    yet). Defensive like `parse_tmdb_list_response`: a malformed episode
    entry (missing number) is skipped rather than crashing the batch.
    """
    items: list[WorkItem] = []
    for entry in payload.get("episodes", []):
        episode_number = entry.get("episode_number")
        season_number = entry.get("season_number")
        if episode_number is None or season_number is None:
            continue
        if not _has_aired(entry.get("air_date"), today):
            continue
        items.append(
            WorkItem(
                tmdb_id=tmdb_id,
                type="tv",
                title=show_title,
                year=show_year,
                season=int(season_number),
                episode=int(episode_number),
                reason="episode",
            )
        )
    return items


def _has_aired(air_date: str | None, today: date) -> bool:
    """An episode has aired if it carries a parseable `air_date` on/before `today`.

    No air_date at all -> treated as not-yet-aired (conservative: don't
    generate trivia for an episode TMDB hasn't dated yet).
    """
    if not air_date:
        return False
    try:
        aired = date.fromisoformat(air_date)
    except ValueError:
        return False
    return aired <= today


def build_episode_work_items(
    show_items: list[WorkItem],
    episodes_by_show: dict[int, list[WorkItem]],
    published_keys: set[str],
) -> list[WorkItem]:
    """Pure: expand TV show-level work items into per-episode work items.

    `episodes_by_show` maps a show's `tmdb_id` -> the full list of aired
    episode WorkItems already parsed for that show (across all its
    seasons — the caller fetches/parses per season, this just does the
    show-level fan-out + freshness filtering). Only `type == "tv"`,
    show-level items (no season/episode already set) are expanded; a
    movie or an already-episode-level item passed in here is ignored (the
    show-level item itself is kept separately by the caller — this
    function only returns the NEW episode items).

    Freshness: an episode already present in `published_keys` (already has
    trivia published for it) is skipped, so re-running seed after new
    episodes air only enqueues the new ones — idempotent by construction.
    """
    seen: set[str] = set()
    result: list[WorkItem] = []
    for show_item in show_items:
        if show_item.type != "tv" or show_item.season is not None or show_item.episode is not None:
            continue
        for episode_item in episodes_by_show.get(show_item.tmdb_id, []):
            if episode_item.key in published_keys or episode_item.key in seen:
                continue
            seen.add(episode_item.key)
            result.append(episode_item)
    return result


def load_published_keys(path: Path) -> set[str]:
    """Read the `published.jsonl` manifest (appended to by the publish stage).

    Each line is `{"key": "<WorkItem.key>", "published_at": "<iso8601>"}`.
    Missing file -> empty set (first run before anything has published yet).
    Malformed lines are skipped defensively rather than crashing seed.
    """
    if not path.exists():
        return set()
    keys: set[str] = set()
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
                keys.add(d["key"])
            except (json.JSONDecodeError, KeyError):
                continue
    return keys


def append_published_keys(keys: list[str], path: Path, *, published_at: str) -> None:
    """Append newly-published work-item keys to the `published.jsonl` manifest.

    Called by the publish stage after a successful upload. Append-only (not
    rewritten) so the manifest is safe to grow across many pipeline runs
    without re-reading/re-writing the whole file each time.
    """
    if not keys:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        for key in keys:
            f.write(json.dumps({"key": key, "published_at": published_at}) + "\n")


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


def _fetch_tmdb_show_season_count(config: Config, tmdb_id: int) -> int:
    """Number of seasons for a show, via tmdb-proxy's existing `details` route."""
    url = f"{config.tmdb_proxy_base_url}/tmdb/details/{tmdb_id}"
    resp = requests.get(url, params={"type": "tv"}, timeout=30)
    resp.raise_for_status()
    return int(resp.json().get("number_of_seasons", 0) or 0)


def _fetch_tmdb_season(config: Config, tmdb_id: int, season_number: int) -> dict[str, Any]:
    url = f"{config.tmdb_proxy_base_url}/tmdb/season/{tmdb_id}"
    resp = requests.get(url, params={"season": season_number}, timeout=30)
    resp.raise_for_status()
    return resp.json()


def _fetch_episodes_for_show(config: Config, show_item: WorkItem, today: date) -> list[WorkItem]:
    """Fetch every season for a show and return its aired episode WorkItems.

    One show with a bad/missing season doesn't sink the whole show — each
    season fetch is try/except'd individually, same defensive posture as
    the TMDB list fetch in `run()`.
    """
    try:
        season_count = _fetch_tmdb_show_season_count(config, show_item.tmdb_id)
    except requests.RequestException as exc:
        logger.warning("TMDB show details fetch failed (tv/%d): %s", show_item.tmdb_id, exc)
        return []

    episodes: list[WorkItem] = []
    for season_number in range(1, season_count + 1):
        try:
            payload = _fetch_tmdb_season(config, show_item.tmdb_id, season_number)
        except requests.RequestException as exc:
            logger.warning(
                "TMDB season fetch failed (tv/%d season %d): %s",
                show_item.tmdb_id,
                season_number,
                exc,
            )
            continue
        episodes.extend(
            parse_tmdb_season_response(
                payload,
                tmdb_id=show_item.tmdb_id,
                show_title=show_item.title,
                show_year=show_item.year,
                today=today,
            )
        )
    return episodes


def run(config: Config) -> list[WorkItem]:
    """IO shell: fetch TMDB lists + Plex library + re-curation file, build+write seed.jsonl.

    Also enumerates episodes for every TV show in the merged list (P3
    content freshness): fetches each show's season list from TMDB via
    tmdb-proxy, filters to aired episodes, and skips any episode already
    present in the `published.jsonl` manifest so a re-run after new
    episodes air only enqueues what's new.
    """
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

    # Popular-only by default: cover all popular/trending content regardless of
    # any library. Set INSIGHTS_LIBRARY_ONLY=1 to instead intersect with a Plex
    # library dump (the only mode that needs Plex).
    plex_ids: set[tuple[MediaType, int]] | None = None
    if config.library_only:
        try:
            plex_payload = _fetch_plex_library_dump(config)
            plex_ids = parse_plex_library_response(plex_payload)
        except requests.RequestException as exc:
            logger.error("Plex library dump failed: %s", exc)
            plex_ids = set()

    seed_list = build_seed_list(recurate_items, tmdb_candidates, plex_ids)

    # Episode enumeration: expand every TV show-level item into its aired,
    # not-yet-published episodes.
    published_keys = load_published_keys(config.data_dir / "published.jsonl")
    show_items = [item for item in seed_list if item.type == "tv"]
    episodes_by_show: dict[int, list[WorkItem]] = {}
    # UTC, not host-local: TMDB air_date is a plain date and the pipeline host's
    # timezone must not shift the aired/not-aired boundary for a same-day episode.
    today = datetime.now(UTC).date()
    for show_item in show_items:
        episodes_by_show[show_item.tmdb_id] = _fetch_episodes_for_show(config, show_item, today)
    episode_items = build_episode_work_items(show_items, episodes_by_show, published_keys)
    seed_list = seed_list + episode_items

    logger.info(
        "seed: %d recurate + %d tmdb-candidates -> %d work items (%s), +%d new episodes across %d shows",
        len(recurate_items),
        len(tmdb_candidates),
        len(seed_list) - len(episode_items),
        "library-only" if config.library_only else "popular-only",
        len(episode_items),
        len(show_items),
    )
    write_seed_jsonl(seed_list, config.data_dir / "seed.jsonl")
    return seed_list
