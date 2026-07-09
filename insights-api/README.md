# insights-api

Cloudflare Worker serving Rivulet Insights trivia JSON from the `rivulet-insights` R2 bucket.

## Routes
- `GET /insights/movie/{tmdbId}` — movie trivia JSON (24h edge cache)
- `GET /insights/tv/{tmdbId}/{season}/{episode}` — episode trivia JSON (24h edge cache)
- `GET /insights/suppressed` — array of suppressed fact ids (5m cache; empty until P2b)
- `POST /report` — fact report sink (stubbed 202 until P2b)

R2 is bound natively (`INSIGHTS` binding → `rivulet-insights` bucket); no S3 credentials needed.

## Deploy
```
npx wrangler deploy
```

## Object layout in R2 (written by the pipeline's publish stage)
- `insights/movie/{tmdbId}.json`
- `insights/tv/{tmdbId}/{season}/{episode}.json`
- `suppressed/index.json` (P2b)
