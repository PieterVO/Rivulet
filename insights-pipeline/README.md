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
# stages, in order: seed, discover, fetch, extract, verify, publish
```

Or in Docker (no `docker compose` needed):

```bash
docker build -t insights-pipeline .
docker run --rm --env-file .env -v "$PWD/data:/app/data" insights-pipeline <stage>
```

## Pipeline stages

| Stage | What it does |
|---|---|
| `seed` | Build the work list: TMDB popular/trending ∩ your Plex library, + re-curation queue |
| `discover` | Resolve each title to its Wikipedia article + Fandom wiki/page (LLM-adjudicated) |
| `fetch` | Pull section-filtered page content via the MediaWiki API, cached to disk |
| `extract` | Local LLM turns prose into schema facts (grounded, rewritten, spoiler-tagged) |
| `verify` | The gate: drops ungrounded/malformed/filler/duplicate facts, re-checks category+spoiler, emits an HTML spot-check report |
| `publish` | Assemble published JSON, upload to R2 |

Each stage is idempotent and resumable — it reads the prior stage's on-disk output and
writes its own, so a batch can restart from any point.

## Tests

```bash
.venv/bin/python -m pytest tests/ -q
```

All tests mock the LLM and network — no live calls, no box access required.

## Publishing to R2

`publish` uploads via `wrangler r2 object put <bucket>/<key> --file <f> --remote`
(wrangler's OAuth session; no R2 API token needed). **The `--remote` flag is required** —
without it wrangler writes a local simulation store and the deployed Worker sees nothing.
A boto3/S3 path is used instead when `INSIGHTS_R2_*` credentials are set (for unattended runs).

## Object layout in R2

- `insights/movie/{tmdbId}.json`
- `insights/tv/{tmdbId}/{season}/{episode}.json`
- `suppressed/index.json` (P2b)
