# TMDB Proxy Worker (Cloudflare Workers)

Thin TMDB proxy that keeps your API key server-side and caches responses at the edge. All setup can be done from the CLI with Wrangler.

## Files
- `wrangler.toml` — Worker config
- `src/index.ts` — Worker code (GET-only, cached, CORS-enabled)

## Prereqs
- Node.js + npm
- Cloudflare account
- TMDB API key

## Install Wrangler (CLI)
- Preferred: `npm install -g wrangler` or use ad hoc `npx wrangler@latest <command>`
- Note: Homebrew’s `wrangler` formula is disabled; use npm instead.

## Configure & Run
```bash
cd tmdb-proxy

# 1) Login to Cloudflare
wrangler login

# 2) Add your TMDB key as a secret (stored on CF, never client-side)
wrangler secret put TMDB_API_KEY

# 3) Local dev (http://localhost:8787)
wrangler dev

# 4) Deploy to Workers
wrangler deploy
```

## Endpoints (client-facing)
- `/tmdb/keywords/{tmdbId}?type=movie|tv[&language=en-US]`
- `/tmdb/credits/{tmdbId}?type=movie|tv[&language=en-US]`
- `/tmdb/details/{tmdbId}?type=movie|tv[&language=en-US]`

Responses are passed through from TMDB, with `Cache-Control` set (default 7 days) and CORS open for GET.

## Notes
- Edge cache: `caches.default` + `Cache-Control` header; tweak `TTL_SECONDS` in `src/index.ts`.
- Secrets: Only `TMDB_API_KEY` is required.
- If you prefer JS instead of TS, you can change `main` to `src/index.js` and transpile manually.
