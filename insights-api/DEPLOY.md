# Worker Lockdown — Deployment Runbook

The Workers now require Apple App Attest. This is the order to roll it out, and
the order matters: deploying the Workers in `enforce` before the attesting app
ships would break every live install.

Nothing here is destructive if followed in sequence. Every step is reversible.

## What you need first

1. **Your Team ID.** Apple Developer → Membership. It's the 10-character string.
2. **App Attest enabled on the App ID.** Apple Developer → Identifiers →
   `com.gstudios.rivulet` → check **App Attest**. Save. Then regenerate the
   provisioning profiles (Xcode → Settings → Accounts → Download Manual Profiles,
   or just let automatic signing re-fetch).
3. **Two secrets you invent.** Any long random strings, e.g.
   `openssl rand -hex 32`. One for the Unraid pipeline, one for the Simulator.

## Step 1 — set the real APP_ID

`APP_ID` is `TEAMID.bundleid` and is currently the placeholder
`TEAMID.com.gstudios.rivulet`. Apple bakes this identity into every attestation,
so if it's wrong, **every** attestation is rejected.

Edit `APP_ID` in BOTH `insights-api/wrangler.toml` and `tmdb-proxy/wrangler.toml`:

```toml
APP_ID = "ABCDE12345.com.gstudios.rivulet"   # <- your real Team ID
```

## Step 2 — set the secrets

```bash
cd insights-api
npx wrangler secret put SERVER_KEY    # paste the pipeline secret
npx wrangler secret put DEV_KEY       # paste the simulator secret

cd ../tmdb-proxy
npx wrangler secret put SERVER_KEY    # SAME value as above
npx wrangler secret put DEV_KEY       # SAME value as above
npx wrangler secret put TMDB_API_KEY  # only if not already set
```

Secrets never go in `wrangler.toml` and never get committed.

## Step 3 — deploy insights-api FIRST

It owns the Durable Objects, and `tmdb-proxy` binds to them across scripts. The
DO classes must exist before the other Worker references them.

```bash
cd insights-api
npm run check          # typecheck + 36 tests
npx wrangler deploy    # creates the DeviceRegistry / ChallengeStore DOs
```

## Step 4 — deploy tmdb-proxy

```bash
cd tmdb-proxy
npm run check
npx wrangler deploy
```

Both ship with `ATTEST_MODE = "observe"`, so **nothing breaks yet**: old builds
keep working. The one exception is deliberate — `POST /insights/request` is
enforced immediately (it's app-only and is the endpoint that costs money and
feeds the LLM).

## Step 5 — point the pipeline at its secret

On Unraid, add to the pipeline's environment:

```bash
INSIGHTS_TMDB_PROXY_SERVER_KEY=<the SERVER_KEY you set above>
```

Verify the seed stage still reaches TMDB before moving on.

## Step 6 — ship the app

Set the entitlement environment for the build you're shipping. In
`Rivulet/Rivulet.entitlements`:

- **development** — local/dev builds (current value).
- **production** — TestFlight and App Store. Change it before archiving, or
  every attestation is rejected on-device.

Then ship. On first launch each device attests once and caches its key id in the
Keychain.

## Step 7 — WAIT, then enforce

This is the whole point of the grace period: let already-shipped builds (which
cannot attest, and never will) drain out of the field. Give it a few weeks.

When you're ready, flip the reads closed. It's a config change, not a deploy:

```toml
# in BOTH wrangler.toml files
ATTEST_MODE = "enforce"
```

```bash
cd insights-api && npx wrangler deploy
cd ../tmdb-proxy && npx wrangler deploy
```

## Verify it actually worked

From any machine:

```bash
# Both must return 401.
curl -i https://tmdb-proxy.baingurley.workers.dev/tmdb/details/27205?type=movie
curl -i -X POST https://insights-api.baingurley.workers.dev/insights/request \
  -H 'Content-Type: application/json' \
  -d '{"type":"movie","tmdbId":27205,"title":"x"}'
```

The write path returns 401 immediately (from step 3). The read path returns 401
only after step 7.

## Rolling back

Set `ATTEST_MODE = "observe"` and redeploy. That reopens the reads. The write
path stays enforced by design; if you truly need it open, remove the
`writePath ? { ...env, ATTEST_MODE: "enforce" }` override in
`insights-api/src/index.ts`.

## Things that will bite you

- **Simulator can't attest.** `DCAppAttestService.isSupported` is `false` there
  (no Secure Enclave) — verified, not assumed. Run the sim with
  `RIVULET_DEV_KEY=<your DEV_KEY>` in the scheme's environment. The dev path is
  `#if DEBUG`, so it cannot exist in a release binary.
- **`development` vs `production` entitlement.** Attestations minted against the
  wrong Apple environment are rejected. This is the single easiest way to ship a
  broken build.
- **Deploy order.** `insights-api` before `tmdb-proxy`, always — the DO classes
  must exist before the cross-script binding resolves.
- **The shared crypto is duplicated.** `attest.ts` and `guard.ts` exist in both
  Workers; `insights-api` is the source of truth. A test in `tmdb-proxy` fails
  the build if they drift, so fix one and copy it over.
