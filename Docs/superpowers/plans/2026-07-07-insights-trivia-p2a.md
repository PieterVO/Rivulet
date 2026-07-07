# Insights Trivia P2a (Pipeline + Read Path) Implementation Plan

> **For agentic workers:** use superpowers:subagent-driven-development. The pipeline is Python; the Worker is TypeScript; the client is Swift. These are three loosely-coupled subsystems — build in the order below (pipeline first, it produces the data the others consume).

**Goal:** Stand up the offline trivia pipeline (seed→discover→fetch→extract→verify→publish) producing per-title JSON on Cloudflare R2, a Worker serving it, and a read-only Trivia section in the tvOS Insights panel.

**Architecture:** A Python package `insights-pipeline/` runs in Docker on the Unraid box, calls Ollama (`http://<unraid>:11434/v1`) for extract+verify, and uploads JSON to R2. A new Cloudflare Worker `insights-api/` (R2-bound) serves GET routes. The Rivulet client fetches trivia alongside cast and renders it in the existing Insights panel.

**Tech Stack:** Python 3.11 (pipeline), Ollama/qwen2.5-32b (LLM), Cloudflare Worker + R2 (serving), Swift 6/UIKit (client). Spec: `Docs/superpowers/specs/2026-07-07-insights-trivia-pipeline-design.md`.

## Global Constraints

- **Pipeline is model-agnostic via an OpenAI-compatible endpoint.** Ollama base URL, model name, R2 creds all come from env/config — NEVER hardcoded. Default model `qwen2.5:32b-instruct` (present on the box; the bake-off in Phase 0 may change it).
- **Extraction is strict extract-and-rewrite.** The prompt MUST forbid any fact not grounded in the provided source text. Every fact carries `sourceSnippet` (the source sentence(s)) through verify; `publish` strips it.
- **Stages are idempotent and resumable** — each reads the prior stage's on-disk output and writes its own; re-running a stage is safe.
- **`fact.id` is stable** = short hash of `text` + `source.url`, so reports/suppression survive re-publish.
- **Unraid facts:** Python 3.11.15, Docker 27.5.1, NO `docker compose` plugin (use `docker build` + `docker run`). ollama container is up on port 11434 with `qwen2.5:32b-instruct`, `qwen3.5:27b-q4_K_M`, `gemma4:31b-it-q4_K_M` present. GPU ~27GB free. SSH: `root@192.168.1.140`. Plex runs on the same box for the library dump.
- **Secrets never committed.** R2 keys, any tokens → `.env` (gitignored) + `.env.example` documenting the keys. `Docs/` is gitignored in this repo; docs commits use `git add -f`.
- Branch: `feature/insights-trivia-p2a` off `feature/insights-cast-panel` (so it has the P1/actor Insights panel to hang the Trivia section on). Commit locally; do not push.
- Python: type-hinted, `ruff`-clean, tested with `pytest`. Each stage is a module with a pure core (testable without network/LLM) + a thin IO shell.

---

## Phase 0 — Extraction bake-off (decides the model + prompt BEFORE building the pipeline)

### Task 0.1: Bake-off harness + fixtures
**Files:** `insights-pipeline/bakeoff/run_bakeoff.py`, `insights-pipeline/bakeoff/fixtures/` (5 hand-picked source excerpts: 1 popular movie, 1 obscure movie, 1 TV episode, 1 lore-heavy franchise page, 1 thin/near-empty page), `insights-pipeline/bakeoff/prompts/extract_v1.txt`
- [ ] Write `run_bakeoff.py`: for each (fixture × model × prompt), call the Ollama `/v1/chat/completions` endpoint, parse the JSON fact array, and emit an HTML report (fact | category | spoiler | sourceSnippet | source-grounded? yes/no by a second verify call). Models to compare: `qwen2.5:32b-instruct`, `qwen3.5:27b-q4_K_M`, `gemma4:31b-it-q4_K_M`.
- [ ] Write `extract_v1.txt`: strict extract-and-rewrite system prompt — categories enum (production/casting/adaptation/reference/lore/goof/music), spoiler 0/1/2 definition, "emit ONLY facts grounded in the provided text, rewrite don't quote, one self-contained fact per entry, JSON array only."
- [ ] Run it on the Unraid box (SSH); write reports to `insights-pipeline/bakeoff/out/`.
- [ ] Commit harness + fixtures + prompt + the generated reports.

### Task 0.2: Council review of bake-off → pick model + prompt
- [ ] This is a COUNCIL decision (see the controller's council note). Dispatch 3 reviewers (different lenses: factual-accuracy/hallucination, spoiler-tagging correctness, category+rewrite quality) over the HTML reports; synthesize a verdict: which model, which prompt fixes are needed.
- [ ] Record the decision in `insights-pipeline/bakeoff/DECISION.md` and update the default model + `extract_v1.txt`→`extract.txt` accordingly. Commit.

---

## Phase 1 — Pipeline package

### Task 1.1: Package skeleton + config + Docker
**Files:** `insights-pipeline/pyproject.toml`, `insights-pipeline/insights/__init__.py`, `insights/config.py`, `insights/models.py` (dataclasses: `Fact`, `TitleTrivia`, `SourceMap`), `insights/io.py` (stage on-disk read/write helpers), `Dockerfile`, `.env.example`, `.dockerignore`, `insights-pipeline/README.md`, `RivuletTests`-style `insights-pipeline/tests/test_models.py`
- [ ] `config.py`: load Ollama base URL, model, R2 endpoint/bucket/keys, data dir, rate limits from env. `models.py`: the schema dataclasses matching the spec's JSON, with `fact_id(text, source_url)` hash helper. Test the hash is stable + the dataclasses round-trip to/from the published JSON shape.
- [ ] `Dockerfile`: python:3.11-slim, install deps, entrypoint `python -m insights <stage> [args]`. `docker run` mounts the repo's `insights-pipeline/` + a data volume; talks to ollama at the host IP. Document the exact `docker build`/`docker run` invocation in the README (no compose).
- [ ] Commit.

### Task 1.2: seed stage
**Files:** `insights/stages/seed.py`, `tests/test_seed.py`
- [ ] Build the work list: TMDB popular+trending (movies+TV) via the existing `tmdb-proxy` (reuse it — don't re-implement TMDB access), intersect with a Plex library dump (Plex API on the same box; server URL/token from env), then popularity order. Also merge the re-curation priority list (P2b feeds it; for now it's an optional empty file). Output `seed.jsonl` (one work item per line: tmdbId, type, title, year, S/E for episodes). Pure list-building logic tested with fixture inputs.
- [ ] Commit.

### Task 1.3: discover stage
**Files:** `insights/stages/discover.py`, `tests/test_discover.py`
- [ ] Per work item: resolve Wikipedia article (Wikipedia API opensearch/query by title+year+type) and Fandom wiki+page (Fandom search + an LLM adjudication call "is this page about X (year, type)?"). Output `sourcemap.jsonl`. The candidate-ranking + adjudication-decision logic is pure and tested; the network calls are shelled out. Ambiguous/no-match → logged + skipped, not guessed.
- [ ] Commit.

### Task 1.4: fetch stage
**Files:** `insights/stages/fetch.py`, `tests/test_fetch.py`
- [ ] Pull section-filtered content via MediaWiki Action API for both hosts. Prefer Production/Casting/Development/Reception/Trivia/Continuity sections; drop navboxes/infobox/references. Rate-limit politely; cache raw to disk (`fetch_cache/`). The section-selection + cleanup logic is pure and tested against fixture wikitext.
- [ ] Commit.

### Task 1.5: extract stage
**Files:** `insights/stages/extract.py`, `insights/llm.py` (OpenAI-compatible client wrapper), `tests/test_extract.py`
- [ ] `llm.py`: thin chat-completions client (base URL + model from config), JSON-array response parsing with a repair retry on malformed output. `extract.py`: per title, feed each fetched section + the `extract.txt` prompt, collect `Fact`s with category/spoiler/source/sourceSnippet. Output `facts_raw.jsonl`. Test the parsing/repair + fact assembly with a mocked LLM client (no live calls in unit tests).
- [ ] Commit.

### Task 1.6: verify stage
**Files:** `insights/stages/verify.py`, `insights/verify_prompt.txt`, `tests/test_verify.py`
- [ ] Per fact: LLM re-checks `text` against its `sourceSnippet` (supported? spoiler tag correct?) → keep/drop/retag. Output `facts_verified.jsonl` + a per-batch HTML spot-check report (`reports/<batch>.html`: fact ↔ snippet ↔ source link, spoiler tag, drop reasons). Compute+log drop-rate. Mocked-LLM unit tests for keep/drop/retag decisions.
- [ ] Commit.

### Task 1.7: publish stage
**Files:** `insights/stages/publish.py`, `tests/test_publish.py`
- [ ] Assemble the published `TitleTrivia` JSON (strip `sourceSnippet`, keep attribution), key it (`insights/movie/{id}.json` / `insights/tv/{id}/{s}/{e}.json`), upload to R2 via S3-compatible API (boto3), bump `generatedAt`. Test the payload assembly + key derivation (upload shelled/mocked).
- [ ] Commit.

### Task 1.8: end-to-end dry run on Unraid
- [ ] Build the image on the box, run seed→verify for ~5 real titles from the library (NO publish / no R2 yet — dump JSON to disk), eyeball the spot-check report. Fix prompt/section issues surfaced. Record results in `insights-pipeline/DRYRUN.md`. Commit.

---

## Phase 2 — Serving Worker

### Task 2.1: insights-api Worker (GET routes + R2)
**Files:** `insights-api/src/index.ts`, `insights-api/wrangler.toml`, `insights-api/README.md`
- [ ] New Worker (sibling to tmdb-proxy) with an R2 bucket binding. Routes: `GET /insights/movie/{tmdbId}`, `GET /insights/tv/{tmdbId}/{season}/{episode}` → read the R2 object, long edge-cache, CORS, gzip; 404 → record to Analytics Engine keyed by id. `GET /insights/suppressed` → empty array for now (P2b fills it), short TTL. Curl-tested against real R2 objects from Task 1.8's publish.
- [ ] Wire Task 1.7 publish to this Worker's bucket; do a real publish of the dry-run titles; verify GET returns them.
- [ ] Commit.

---

## Phase 3 — Client Trivia section

### Task 3.1: Trivia model + fetch
**Files:** `Rivulet/Services/Insights/InsightsTriviaClient.swift`, `Rivulet/Models/Insights/TriviaFact.swift`, tests
- [ ] `TriviaFact`/`TitleTrivia` Codable models matching the published JSON; `InsightsTriviaClient` fetching movie/episode trivia + the suppressed list from the Worker (base URL in config, same pattern as `TMDBConfig`). Decode + spoiler/suppression filter unit-tested.
- [ ] Commit.

### Task 3.2: VM wiring + panel section
**Files:** `UniversalPlayerViewModel.swift` (add `@Published insightsTrivia`), `PlayerInsightsPanelView.swift` / the two-state panel (add a Trivia section below Cast), tests where practical
- [ ] Load trivia in the same per-item flow as cast; render a Trivia list in the panel (category-ordered, attribution footer), governed by the existing hide-spoilers toggle + suppressed ids. No Report button yet (P2b). Graceful absent state.
- [ ] Build; fold verification into the sim checklist. Commit.

---

## Self-review checklist
- No secrets committed; `.env.example` documents every key.
- Every stage idempotent + resumable; pure cores unit-tested with mocked IO/LLM.
- Extraction prompt forbids ungrounded facts; verify drops unsupported; `sourceSnippet` stripped on publish.
- `fact.id` stable across re-publish.
- Worker fact JSON immutable/long-cached; suppressed list separate + short-TTL.
- Client Trivia section degrades to absent on any failure.
