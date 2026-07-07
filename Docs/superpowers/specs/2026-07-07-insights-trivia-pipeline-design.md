# Insights Trivia — Pipeline & Feature Design (P2)

**Date:** 2026-07-07
**Status:** Approved design, pre-implementation
**Builds on:** `2026-07-07-insights-panel-design.md` (the umbrella Insights design; this narrows and
supersedes its pipeline/serving sections with concrete decisions). P1 (the cast panel) is separate
and already built. This spec is the **trivia** — the differentiator.

---

## What we're building

Deep trivia (production facts, casting stories, adaptation notes, lore, references, goofs) for a
title/episode, generated offline by a local LLM pipeline on a local GPU host, published
as static JSON on Cloudflare R2, and surfaced as a **Trivia section in the Insights panel** (the
same panel that shows Cast) and on pause. Each fact carries a spoiler level and a source
attribution. Users can **report** a bad fact; enough reports auto-hide it pending re-curation.

**Not in this phase:** subtitle-anchored timestamp sync (facts appear on demand in the panel /
on pause, not timed to the playhead) — deferred, layered on the same fact store later.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Extraction model | **Local only** — Ollama on the local GPU host does ALL bulk extraction, unattended, zero cost. No hosted API in the loop. |
| Claude's role | **Spot-check auditor**, not bulk extractor. Claude Code (Max seat) reviews the HTML spot-check reports and pulls bad titles — a human-in-the-loop that happens to be an LLM, run interactively, not wired into the headless pipeline. |
| Curation gate | **Auto-publish** gated by the pipeline's own LLM verify-pass + a **sampled** spot-check. Titles go live without per-title human sign-off; the sample + user reports catch escapes. |
| Display | **Panel + pause only.** Trivia section in the Insights panel; no per-fact playhead timing. |
| Sources | Wikipedia + Fandom (facts rewritten, CC BY-SA attribution carried), TMDB for the frame. IMDb not used. |
| Spoilers | Every fact tagged `spoiler` 0/1/2; a single client "hide spoilers" toggle hides `>= 1`. |
| Feedback | In-panel **Report** button: reasons `inaccurate` / `wrong_time` / `spoiler` / `other`. |
| Report sink | Cloudflare **Worker `POST /report`** → append to an R2 reports prefix (or Queue). Drained into the pipeline's re-curation priority list. |
| Report effect | **Auto-hide at a threshold**: once N distinct users report a fact, the client suppresses it via a small Worker-served suppression list; the fact is queued for review. |

## Pipeline (`insights-pipeline/`, runs in Docker on the GPU host)

Six idempotent, resumable stages. Each writes its output to disk so a batch resumes from any
point. Runs as a Docker container with the repo dir mounted, talking to Ollama over the host
network; invoked manually or on a schedule.

```
seed ──▶ discover ──▶ fetch ──▶ extract ──▶ verify ──▶ publish
  │         │           │          │           │          │
popular/  wiki+fandom  MediaWiki  Ollama:     Ollama:    upload JSON to R2,
trending  page match   API pull   prose →     re-check    write spot-check
∩ library (LLM adjud.) (cached)   schema      each fact   report, refresh
                                  facts       vs source   suppression inputs
```

### 1. seed — build the work list
TMDB popular + trending (movies & TV) intersected first with a Plex library dump (Plex is on the
same box → local API call) for validation, then popularity outward. Also consumes the
**re-curation priority list** (titles with queued reports) so reported content re-runs ahead of
new titles. Explicit list-in / list-out; logs what was included and why.

### 2. discover — locate sources
Per title: find the Wikipedia article and (if any) the Fandom wiki + specific page (episode page
for TV). Heuristics (title + year + type) narrow candidates; a local-LLM adjudication step
confirms ("Is this page about *Inception* (2010 film)? yes/no"). Output: a source map
`tmdb → {wikipediaURL, fandomWiki, fandomPageURL}`, cached so re-runs skip re-discovery. Ambiguous/
no-match titles are logged and skipped (no bad-source extraction).

### 3. fetch — pull page content
MediaWiki Action API for both Wikipedia and the resolved Fandom wiki. Polite rate limiting,
on-disk cache of raw wikitext/HTML. Section-aware (prefer Production / Casting / Development /
Reception / Trivia / Continuity sections; skip navboxes, infobox dumps, reference lists).

### 4. extract — Ollama, prose → schema facts
A strong local instruct model (target: a 27–32B-class model, e.g. Qwen2.5-32B-Instruct or
Llama-3.3-70B q4 — pick per VRAM headroom on the GPU's available VRAM) in **strict
extract-and-rewrite mode**: for each source section, emit schema facts, each with `category`,
`spoiler` level, and the exact `source` (name + URL) and a `sourceSnippet` (the sentence(s) the
fact came from — retained only for the verify pass, not published). The model NEVER invents;
prompt forbids any fact not grounded in the provided text. Batched per title/episode.

### 5. verify — Ollama, the automated gate
A second local-LLM pass re-reads each fact **against its own `sourceSnippet`** and drops anything
unsupported, contradicted, or vague. Also re-checks the `spoiler` tag. This is the curation gate
the earlier spec called for, automated. Emits a per-batch **HTML spot-check report** (each surviving
fact next to its source snippet + link, spoiler tag visible) — this is what Claude Code / you
sample-audit. Drop-rate per batch is a quality signal (a spiking drop-rate flags a bad
extract prompt or a bad source).

### 6. publish — upload
Write the final per-title / per-episode JSON to R2 (S3-compatible API), strip `sourceSnippet`
from the published payload (attribution URL stays). Immutable per `generatedAt`; re-publish on
re-curation bumps `generatedAt` and invalidates the edge cache for that key.

**Model config:** OpenAI-compatible endpoint (Ollama's `/v1`); model name in pipeline config so the
extract/verify model can be swapped without code changes. The `ollama` container already exists on
the box (GPU passthrough, port 11434, an ollama data volume) but has never been started —
setup is `docker start ollama` + `ollama pull <model>`.

## Fact store schema

One JSON file per movie / per episode. Published shape (`sourceSnippet` stripped):

```json
{
  "id": "tmdb://27205",
  "type": "movie",
  "generatedAt": "2026-07-07T00:00:00Z",
  "pipelineVersion": 1,
  "attribution": [ { "name": "Wikipedia", "url": "…" }, { "name": "Inception Wiki", "url": "…" } ],
  "facts": [
    {
      "id": "f_a1b2c3",              // stable per fact (hash of text+source); the report/suppress key
      "text": "Rewritten, self-contained fact.",
      "category": "production",      // production | casting | adaptation | reference | lore | goof | music
      "spoiler": 0,                  // 0 none · 1 this title's plot · 2 later episodes/seasons
      "source": { "name": "Wikipedia", "url": "…" }
    }
  ]
}
```

`fact.id` is stable across re-publishes (hash of `text` + `source.url`) so reports and the
suppression list survive re-curation of a title.

## Serving (Cloudflare Worker + R2)

Extends the same Worker/R2 stack pattern as `tmdb-proxy`.

| Route | Method | Purpose |
|---|---|---|
| `/insights/movie/{tmdbId}` | GET | movie trivia JSON (edge-cached, long TTL, immutable per `generatedAt`) |
| `/insights/tv/{tmdbId}/{season}/{episode}` | GET | episode trivia JSON |
| `/insights/suppressed` | GET | small JSON array of suppressed `fact.id`s (SHORT TTL, e.g. 5 min — this is the one dynamic read) |
| `/report` | POST | body `{ contentId, factId, reason, clientId }` → append to R2 reports prefix / Queue |

- **Miss logging:** GET 404s recorded to Workers Analytics Engine keyed by title id → the seed
  stage's demand signal (KV unsuitable: 1 write/sec/key limit).
- **Suppression** is a SEPARATE endpoint on purpose: the fact JSON stays immutable/long-cached;
  only the tiny suppressed-id list is short-TTL, so a newly-crossed threshold hides a fact within
  minutes without cache-busting every title. The Worker computes the suppressed list from report
  counts (distinct `clientId` per `factId` ≥ threshold); recompute on a cron or on read with a
  short cache.
- No user accounts: `clientId` is an anonymous install id (dedupes report counts, prevents one
  device inflating a threshold). No PII; request carries only ids + a reason enum.

## Client (tvOS) — Trivia in the Insights panel

- **Data:** on player load, alongside the cast fetch, fetch the trivia JSON for the resolved
  TMDB id (movie: `/insights/movie/{id}`; episode: `/insights/tv/{showId}/{s}/{e}`) and the
  `/insights/suppressed` list. Cache in memory for the session; treat as transient (tvOS purgeable).
- **UI:** a **Trivia section** in the Insights panel below Cast (single list ordered by category,
  no filter chips — restraint per design guide). Attribution footer ("Info from Wikipedia ·
  Inception Wiki"). Also available on pause via the same panel.
- **Spoilers:** the P1 "hide spoilers" toggle governs trivia too — with it on, hide `spoiler >= 1`
  (without timestamp sync we can't know what the viewer has passed). Facts in the `/insights/suppressed`
  list are hidden regardless.
- **Report:** each fact row has a Report affordance → a small menu (`Inaccurate`, `Wrong time`,
  `Spoiler`, `Other`) → `POST /report` with `{ contentId, factId, reason, clientId }`. Fire-and-forget;
  a quiet "Thanks" confirmation, no blocking UI. (`Wrong time` is retained as a reason now even
  though timing isn't shown yet — it seeds the signal for the future sync phase.)
- **Absent data:** no tmdb id / 404 / network fail → Trivia section simply absent (same graceful
  rule as Cast). Never an error.

## Phasing within P2

- **P2a — pipeline + read path:** stages 1–6 producing JSON to R2; GET routes; client Trivia
  section (read-only, spoiler toggle, attribution). This is the shippable core.
- **P2b — feedback loop:** `POST /report`, `/insights/suppressed`, client Report button + auto-hide,
  seed-stage re-curation priority from drained reports.

## Testing

- **Pipeline:** golden-file tests per stage (fixture wiki pages → expected facts / expected drops);
  the verify stage's drop-rate + the sampled spot-check report are the quality gates before a batch
  publishes. A bake-off on ~20 library titles sets the model choice and the extract prompt before
  scaling out.
- **Serving:** curl checks for GET hit/miss/CORS/cache headers; `POST /report` append; suppression
  list crossing the threshold hides the right `fact.id`.
- **Client:** unit tests for trivia decode, spoiler+suppression filtering, and report payload
  construction; the panel exercised via `/playback-test` content (183532, 183403 — both popular,
  seed-covered).

## Open risks (call out, don't silently cap)

- **Local-model extraction quality is the whole bet.** If the bake-off spot-checks aren't good
  enough, the fallback is NOT a hosted API (user ruled out spend) — it's a better local model, a
  tighter prompt, or narrowing sources to the highest-signal sections. Log drop-rates and
  sample honestly; do not ship a batch whose spot-check you haven't looked at.
- **Fandom coverage is thin for non-franchise films** — Wikipedia carries those; a title with
  neither yields no trivia (absent section, not an error).
- **Suppression brigading:** distinct-`clientId` counting blunts single-device abuse; a determined
  brigade could still hide a good fact. Acceptable at this scale; revisit if it happens.
