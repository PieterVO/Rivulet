# Insights Panel — Design

**Date:** 2026-07-07
**Status:** Approved design, pre-implementation
**Supersedes/extends:** `Docs/FEATURE_INSIGHTS.MD` (decision record). This spec narrows it to an
approved v1 and revises two of its calls: no on-demand backend in v1, and Wikipedia added as a
co-equal source alongside Fandom.

---

## What we're building

An X-Ray / Apple InSight–style **Insights panel** in the player: cast for the currently playing
title/episode plus deep trivia (production facts, casting stories, adaptation notes, lore,
references), surfaced as a detached panel in the existing player rail. Trivia is the
differentiator; it is pre-generated per title by an offline LLM pipeline and served as static
JSON keyed by TMDB ID.

**Explicitly deferred (not v1):** timestamp-synced facts (subtitle anchoring), on-demand
generation, ShazamKit music ID, auto-show-on-pause.

## Decisions made during brainstorming

| Question | Decision |
|---|---|
| V1 core | Pause-mode cast **and** deep trivia; trivia is the stand-out feature |
| Coverage strategy | Batch-generate by popularity (TMDB popular/trending), validate against Bain's library first, expand outward; on-demand later if needed |
| Spoiler policy | Extract everything, tag each fact with a spoiler level, client setting filters |
| UI entry point | Rail panel only (like Up Next). No auto-show on pause — keeps pause calm per design guide |
| Processing location | Cast: fully in-app (TMDB via existing tmdb-proxy). Trivia: offline pipeline on Unraid + RTX 5090; **no in-app LLM is possible** (Foundation Models framework does not exist on tvOS) |
| Hosting | Cloudflare Worker + R2, same pattern/repo style as tmdb-proxy. Unraid is never in the serving path |

## Architecture

```
                OFFLINE (Unraid + 5090)                              ONLINE
┌──────────────────────────────────────────────────┐   ┌─────────────────────────────────┐
│ seed → discover → fetch → extract → verify →      │   │ Cloudflare Worker + R2          │
│ publish                                           │──▶│  GET /insights/movie/{tmdbId}   │
│ (TMDB popular/trending + library dump as seed;    │   │  GET /insights/tv/{tmdbId}/{s}/{e}│
│  Wikipedia + Fandom + TMDB as sources;            │   │  edge-cached; 404s logged by ID │
│  local LLM extract/rewrite/tag; verify pass;      │   └────────────────┬────────────────┘
│  spot-check report; upload JSON to R2)            │                    │
└──────────────────────────────────────────────────┘   ┌────────────────▼────────────────┐
                                                        │ Rivulet tvOS Insights rail panel │
                                                        │  cast (TMDB in-app) + trivia     │
                                                        └─────────────────────────────────┘
```

### Content identity

Client resolves the playing item to a TMDB ID from the Plex `Guid` array (`tmdb://…`).
- Movies: the item's own TMDB ID → `movie/{id}`.
- TV: **show** TMDB ID (from grandparent metadata) + `parentIndex`/`index` → `tv/{id}/s{S}e{E}`.
  Keying by show+S/E is more robust across sources than per-episode GUIDs.
- Items without a TMDB guid (home media, legacy agents, unmatched): panel shows cast from Plex
  metadata if present, no trivia, graceful "no info" state. Never an error.

## Sources & licensing

| Source | Role | License handling |
|---|---|---|
| Wikipedia | Primary for movies; production/casting/reception sections for everything | CC BY-SA: facts extracted and **rewritten** (facts aren't copyrightable; expression is), attribution URL stored per fact and shown in panel footer |
| Fandom | Depth for TV/franchise: lore, continuity, behind-the-scenes | Same CC BY-SA handling. Wiki+page discovery is an offline pipeline step (LLM adjudicates candidate pages); the tmdb→(wiki,page) mapping is cached in the store |
| TMDB | Cast/crew/images/metadata frame; popular+trending seed lists | Attribution required (already handled app-wide) |
| IMDb | **Not used.** Not redistributable without enterprise license | — |

The LLM operates in strict *extract-and-rewrite-what's-on-the-page* mode. It never generates
trivia. Published JSON is effectively derivative of CC BY-SA text; we carry attribution and do
not claim exclusive rights over the fact store.

## Trivia store schema

One JSON file per movie / per episode (plus an optional show-level file for show-wide facts).
Files are a few KB. Client treats them as transient cache (tvOS purgeable-cache rules).

```json
{
  "id": "tmdb://27205",
  "type": "movie",              // movie | episode | show
  "generatedAt": "2026-07-07T00:00:00Z",
  "pipelineVersion": 1,
  "attribution": [ { "name": "Wikipedia", "url": "…" }, { "name": "Inception Wiki", "url": "…" } ],
  "facts": [
    {
      "text": "Self-contained rewritten fact.",
      "category": "production",  // production | casting | adaptation | reference | lore | goof | music
      "spoiler": 0,              // 0 none · 1 this title's plot · 2 later episodes/seasons
      "source": { "name": "Wikipedia", "url": "…" },
      "people": [3899]           // optional TMDB person IDs, enables deep-link to Person page
    }
  ]
}
```

Schema is versioned via `pipelineVersion`; client ignores unknown fields.

## Pipeline (new `insights-pipeline/` directory in this repo, runs on Unraid)

Six idempotent, resumable stages; each stage writes its output to disk so a batch can be re-run
from any point:

1. **seed** — build the work list: TMDB popular + trending (movies & TV) intersected first with
   a Plex library dump for validation, then popularity outward. Explicit list-in, list-out.
2. **discover** — per title: locate the Wikipedia article and (if any) the Fandom wiki + episode
   pages. Heuristics + LLM adjudication ("is this page about X (2010 film)?"). Output: source map.
3. **fetch** — pull page content via the MediaWiki APIs (both sites), politely rate-limited,
   cached on disk.
4. **extract** — LLM rewrites page content into schema facts with category + spoiler level +
   per-fact source. Strict extraction prompt; batch per episode/title.
5. **verify** — second LLM pass re-reads each fact against its source snippet and drops anything
   unsupported (the curation gate from the decision record, automated). Emits an HTML spot-check
   report (fact ↔ source link) per batch for human eyeballing.
6. **publish** — upload JSON to R2 (S3-compatible API), invalidate edge cache if re-publishing.

**Model:** model-agnostic via an OpenAI-compatible endpoint. Default: local model on the 5090
(vLLM or Ollama; a 27–32B-class instruct model suits extract-and-rewrite). The same pipeline can
point at a hosted API (e.g. Claude Haiku batch, rough estimate ~$0.02/title) if local quality
disappoints. Quality is judged from the spot-check reports on the library-validation batch before
scaling out.

## Serving (Cloudflare)

New Worker route(s) fronting the R2 bucket, in the same style as `tmdb-proxy`:
- `GET /insights/movie/{tmdbId}`, `GET /insights/tv/{tmdbId}/{season}/{episode}`
- Edge cache (long TTL; content is immutable per `generatedAt` re-publish), CORS, gzip.
- **Miss logging:** 404s are written to Workers Analytics Engine keyed by title ID (KV is
  unsuitable: 1 write/sec/key limit). This is the
  prioritization feed for future batches and the hook where phase-3 on-demand plugs in.
- No auth in v1 (public read-only data, no user data flows to the backend — the request carries
  only a TMDB ID).

## tvOS client

- **Entry:** Insights joins the player rail as a detached floating panel, same interaction
  pattern as Up Next (`Views/Player/UIKit/`). Available on both `aether` and `hls` routes —
  chrome-level only, no engine coupling.
- **Panel content:** cast row on top (TMDB credits + guest stars via tmdb-proxy, headshots via
  `CachedAsyncImage`, Select → Person detail page), trivia list below as a single list ordered
  by category (no filter chips in v1 — restraint per design guide), attribution footer
  ("Info from Wikipedia · Inception Wiki").
- **Spoiler setting:** single Settings toggle (hide spoilers — default on / show everything),
  title-only row + descriptor panel copy per `SettingsDescriptors` rules. Toggle on hides
  `spoiler >= 1` everywhere: without timestamp sync we can't know whether the viewer has passed
  a plot point, so this-title plot facts are treated as spoilers too.
- **Data flow:** on player load (not on pause), resolve TMDB ID → fire both fetches
  (trivia JSON; TMDB credits) → cache in memory for the session. Panel opens instantly.
- **Failure handling:** no TMDB guid, 404, or network failure → trivia section absent; cast
  falls back to Plex metadata roles; if nothing at all, the rail item shows a quiet empty state.
  No retries beyond URLSession defaults, no error dialogs.

## Phasing

- **P1 — Cast panel (all in-app, no backend):** rail panel with cast via TMDB + Plex fallback,
  Person-page deep link. Shippable independently.
- **P2 — Trivia:** pipeline + R2/Worker serving + trivia section, spoiler setting, attribution
  footer. Seed = popular/trending ∩ Bain's library, then popularity outward.
- **P3 (optional, later):** on-demand generation driven by the miss log; timestamp-synced facts
  via subtitle-text anchoring (per `FEATURE_INSIGHTS.MD`) if/when wanted.

## Testing

- **Pipeline:** golden-file tests per stage (fixture wiki pages → expected facts); the verify
  stage's drop-rate and the human spot-check report are the quality gates before publish.
- **Client:** unit tests for GUID→TMDB resolution and spoiler filtering; harness runs via
  `/playback-test` content (183532 Interstellar, 183403 1917 — both popular titles the seed
  batch will cover) to exercise the panel on real playback.
- **Serving:** curl checks against Worker routes for hit/miss/CORS/cache headers.
