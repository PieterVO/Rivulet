# insights-pipeline

Offline pipeline that generates trivia for Rivulet's Insights feature. It turns
Wikipedia/Fandom prose into structured, spoiler-tagged trivia JSON keyed by TMDB id,
published to Cloudflare R2 and served by the `insights-api` Worker to the tvOS app.

Extraction runs on a local LLM (Ollama, default `gemma4:31b-it-q4_K_M` — see
`bakeoff/DECISION.md`). No hosted API is used; nothing leaves your machines except the
final published JSON.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install requests boto3 pytest
cp .env.example .env      # fill in your Ollama host, Plex, and (optional) R2 settings
```

All configuration is via env vars (see `.env.example`); nothing is hardcoded.

## Run a stage

```bash
.venv/bin/python -m insights <stage> [args]
# batch stages, in order: seed, discover, fetch, extract, verify, publish
# on-demand / daemon:      serve (one drain), worker (the long-lived loop)
```

Or in Docker — one-shot stage:

```bash
docker build -t insights-pipeline .
docker run --rm --env-file .env -v "$PWD/data:/app/data" insights-pipeline <stage>
```

Or the long-lived worker via compose (the intended deployment on Unraid):

```bash
docker compose up -d --build            # start the worker daemon
docker compose logs -f insights-worker
docker compose exec insights-worker python -m insights serve   # force one on-demand drain
```

## Pipeline stages

| Stage | What it does |
|---|---|
| `seed` | Build the scheduled work list: TMDB popular/trending (popular-only by default; ∩ Plex only if `INSIGHTS_LIBRARY_ONLY=true`), plus age-aware TTL-stale refresh, new airing episodes, and the on-demand re-curation queue — ordered stale → new-episode → popular and capped at `INSIGHTS_SCHEDULED_MAX_TITLES` |
| `discover` | Resolve each title to its Wikipedia article + Fandom wiki/page (LLM-adjudicated) |
| `fetch` | Pull section-filtered page content via the MediaWiki API, cached to disk |
| `extract` | Local LLM turns prose into schema facts (grounded, rewritten, spoiler-tagged) |
| `verify` | The gate: drops ungrounded/malformed/filler/duplicate facts, re-checks category+spoiler, emits an HTML spot-check report |
| `publish` | Assemble published JSON, upload to R2 (a title with zero facts publishes a `covered:false` **tombstone** so "nothing to share" is definitive) |
| `serve` | One on-demand drain: pull up to `INSIGHTS_ONDEMAND_MAX_BATCH` pending requests, run them through discover→publish, delete each served request |
| `worker` | The long-lived loop (below) — the container's command. Drains on-demand first, else does one scheduled title, forever |

Each stage is idempotent and resumable — it reads the prior stage's on-disk output and
writes its own, so a batch can restart from any point.

## On-demand + scheduling (the worker)

The deployed shape is a single long-lived `worker` container that owns the GPU and runs a
priority loop:

1. **On-demand first.** When Rivulet plays a title with no trivia yet, it 404s and POSTs a
   generation request to the public `insights-api` Worker, which drops one object per request
   under `requests/pending/{key}.json` in R2. The worker drains that queue every
   `INSIGHTS_ONDEMAND_POLL_SECS` (default 120s), highest priority, so freshly-requested trivia
   is usually published within a few minutes — before the episode ends. A malformed/poison
   request is logged and deleted, never allowed to wedge the queue.
2. **Then one scheduled title.** When the queue is empty, the loop processes exactly ONE
   scheduled title (so a live viewer never waits behind a batch), then re-checks the queue.
   The scheduled work list is re-seeded every `INSIGHTS_RESEED_INTERVAL_SECS` (default 6h) and
   covers, in priority order: age-aware TTL-stale refresh → new episodes of airing shows →
   fresh popular/trending. The back-catalog of old episodes is **not** bulk-generated; it's
   filled on-demand when someone actually watches it.
3. **Idle.** Nothing pending and nothing scheduled → sleep, then poll again.

One container = one GPU consumer; a `flock` in the data dir rejects a second instance.
Freshness is age-aware: a just-released title re-scrapes every `INSIGHTS_YOUNG_REFRESH_DAYS`
until it's older than its settle window, then drops to the long mature TTL — so new titles keep
catching accreting trivia, then stop wasting GPU once they've settled.

```bash
docker compose up -d --build      # start the worker (reads .env)
```

## Tests

```bash
.venv/bin/python -m pytest tests/ -q
```

All tests mock the LLM and network — no live calls, no box access required.

## Publishing to R2

`publish` auto-selects its uploader: when `INSIGHTS_R2_*` S3 credentials are set (the worker
container, which has no wrangler), it uploads via boto3/S3; otherwise it uses
`wrangler r2 object put <bucket>/<key> --file <f> --remote` (wrangler's own OAuth session, no
R2 API token needed — the interactive-box path). **The `--remote` flag is required** on the
wrangler path — without it wrangler writes a local simulation store and the deployed Worker
sees nothing.

## Object layout in R2

- `insights/movie/{tmdbId}.json`
- `insights/tv/{tmdbId}/{season}/{episode}.json` — episode
- `insights/tv/{tmdbId}/show.json` — show-level (production/casting/overall)
- Any of the above may be a **tombstone** (`covered:false`, empty `facts`) meaning "generated,
  nothing to share" — the client shows no trivia section and stops re-requesting.
- `requests/pending/{key}.json` — the on-demand request queue (one object per request; the
  Worker writes them, the `worker`/`serve` stage drains and deletes them)
- `suppressed/index.json` (P2b)
