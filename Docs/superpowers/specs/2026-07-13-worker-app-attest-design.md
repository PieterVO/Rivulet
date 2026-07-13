# Worker Lockdown via Apple App Attest

**Date:** 2026-07-13
**Status:** Approved, ready for implementation
**Goal:** Only the genuine Rivulet tvOS app can call the Cloudflare Workers. A fork of the app fails. A curl from the internet fails.

## Problem

Both Workers are open to the public internet. Neither checks anything about the caller: no key, no signature, no origin check, no rate limit. Both also send `Access-Control-Allow-Origin: *`, which actively invites third-party callers.

Concretely:

- **`tmdb-proxy`** holds the TMDB API key in `env.TMDB_API_KEY` and spends it for anyone. It is usable as a free, cached, key-less TMDB API by any caller who knows the URL. Exposure: TMDB rate limit, and the TMDB key itself if TMDB notices the traffic.
- **`insights-api`** exposes `POST /insights/request`, which writes a work item into R2 with no auth and no cap. A script can enqueue unlimited junk, costing R2 writes and feeding garbage into the generation pipeline. The attacker-controlled `title` field flows into an LLM prompt, so it is also a prompt-injection surface.

This does **not** affect the privacy posture. The "we have no information there" guarantee holds because the Worker never *reads* anything identifying, not because only the app can call it. An open endpoint that logs nothing still logs nothing. The exposure here is cost and abuse, not user data.

## Why App Attest, and why nothing else works

**Anything the app can send, an attacker can copy.** Bundle ID, User-Agent, a hardcoded API key, an HMAC over the body: all of it ships inside the binary handed to Apple, and all of it is extractable with `strings` on the IPA or a proxy pointed at an Apple TV. A shared secret stops drive-by scraping but does **not** stop a fork, because a fork is built from the same source and carries the same secret.

Verifying a claimed "app identifier" is worth exactly nothing: the app asserts that string in a header, and anyone can type that string.

**App Attest is the only mechanism on tvOS where the credential is unforgeable.** The private key is generated in the Secure Enclave and never leaves it. Apple's servers sign a certificate attesting that this key belongs to bundle ID *X* from team *Y* running on genuine Apple hardware. A fork has a different bundle ID and a different team ID, both of which Apple bakes into the attestation, so a fork cannot produce a valid one. Neither can curl.

Verified availability (SDK headers on disk, Xcode capability DB):

- `DCAppAttestService` — `API_AVAILABLE(macos(11.0), ios(14.0), tvos(15.0), watchos(9.0))`. Available on tvOS 15+. Rivulet targets tvOS 26, so no version floor problem.
- Entitlement `com.apple.developer.devicecheck.appattest-environment` is required (`isRequiredInPlist: true`), and Xcode's capability DB lists `TV_OS` in `supportedSDKs`.
- **`isSupported == false` in the tvOS Simulator** (no Secure Enclave). Empirically verified by running a probe binary in the sim. The design must therefore have a non-attestation path for the simulator.

### Residual risk (accepted)

App Attest does not stop someone running the genuine, unmodified app on their own Apple TV and proxying its traffic. They must keep real Apple hardware in the loop. That is the irreducible limit of attestation on any platform, and it is a far higher bar than curl.

## Free-tier feasibility (measured, not assumed)

The one real unknown was the free plan's **10 ms CPU per invocation** cap. Measured under real `workerd` using the slope method (timing N iterations and differencing, which cancels all HTTP/curl overhead):

| Path | Frequency | CPU per op | Share of 10 ms cap |
|---|---|---|---|
| Attestation (X.509 chain walk, nonce check, keyId derive) | once per device, ever | **0.474 ms** | 4.7% |
| Assertion (one ECDSA verify + counter compare) | every request | **0.036 ms** | 0.36% |

**Conclusion: no payment required.** WebCrypto's ECDSA and SHA-256 are native, so the expensive-sounding chain walk is sub-millisecond. ~21x headroom on the worst path.

Everything else is far inside free limits:

- **SQLite-backed Durable Objects are free-plan eligible** (since Apr 2025; KV-backed DOs are the paid/legacy ones). Use `new_sqlite_classes`.
- Free caps: 100k Worker req/day, 100k DO req/day, 5M DO rows read/day, 100k rows written/day, 5 GB storage. At a few hundred devices and a few thousand requests/day, this is 3+ orders of magnitude of headroom.

## Topology (verified from the code, not assumed)

| | tvOS app | Unraid pipeline | Simulator |
|---|---|---|---|
| **insights-api** | App Attest | **never calls it** | dev secret |
| **tmdb-proxy** | App Attest | server secret | dev secret |

Two facts that shape the design, both confirmed by reading the pipeline source:

1. **Unraid never touches `insights-api`.** The pipeline reaches R2 *directly* over the S3 API with its own credentials (`insights/r2_queue.py` builds a boto3 client against `r2_endpoint_url`). It lists/reads/deletes the pending queue and uploads published trivia without going through the Worker. The Worker only *writes* queue objects; the pipeline drains them out the back. **Locking down `insights-api` cannot break the pipeline.**
2. **The only writer to `POST /insights/request` is the tvOS app** (`InsightsTriviaClient.requestGeneration`, fired from the player). Nothing else calls it. So the write path is app-only and can be slammed shut on day one with zero collateral damage.
3. **Unraid does call `tmdb-proxy`**, from the seed stage only (`insights/stages/seed.py`). A server cannot do App Attest (no Secure Enclave), so it needs a shared secret. A shared secret is appropriate *here* precisely because the client is a machine we physically control and the secret never ships to a user.

## Rollout: the old-builds problem

Rivulet is live with real users. Every shipped build sends no attestation header and cannot be changed. If the Worker starts *requiring* attestation, every existing install gets 401 on every call: no posters, no hero art, no Discover, no trivia. The app doesn't crash, it just looks broken.

**Chosen strategy: split the paths by blast radius.**

- **Write path (`POST /insights/request`) — enforce immediately.** It is app-only, and an old build failing here degrades softly: the user simply doesn't get trivia generated for that title. This closes the abusable hole (R2 junk writes, prompt injection) on day one.
- **Read paths (all TMDB proxy routes, Insights GETs) — grace period, then enforce.** These are what make the UI look broken. Ship the attesting client, run the Worker in `observe` mode (validate if present, serve regardless), wait for old builds to drain, then flip a single env var to `enforce`.

The grace window leaves TMDB quota exposed for a few weeks. Given the endpoints have already been fully open for months, a few more weeks is not what decides this, and the payoff is that enforcement day is a non-event instead of an incident.

Enforcement mode is a plain env var per Worker: `ATTEST_MODE = "observe" | "enforce"`. Flipping it is a config change, not a deploy.

**Observe mode must not violate the privacy posture.** It records only two aggregate counters (attested vs unattested request counts) in a single DO. No IP, no path, no body, no per-request log. Workers observability stays off.

## Architecture

### Protocol

App Attest is two-phase:

1. **Attest (once per device, ever).**
   - App asks the Worker for a one-time challenge: `GET /attest/challenge` → random 32 bytes, stored with a short TTL.
   - App calls `DCAppAttestService.generateKey()` (Secure Enclave keypair) then `attestKey(_:clientDataHash:)` over `SHA256(challenge)`.
   - App POSTs `{keyId, attestationObject}` to `POST /attest/verify`.
   - Worker verifies: CBOR decode → walk leaf ← intermediate ← **Apple App Attest root CA** (pinned in the Worker) → check the nonce extension (OID `1.2.840.113635.100.8.2`) equals `SHA256(authData || SHA256(challenge))` → check `keyId == SHA256(leafPublicKey)` → check `rpIdHash == SHA256("TEAMID.com.gstudios.rivulet")` → check counter is 0.
   - On success, store `{keyId → publicKey, counter: 0}` in a Durable Object. The app persists its `keyId` in the Keychain.

2. **Assert (every request).**
   - App calls `generateAssertion(keyId, clientDataHash: SHA256(requestBody))`.
   - Sends `X-Rivulet-Key-Id` and `X-Rivulet-Assertion` headers.
   - Worker looks up the DO by `keyId`, verifies the ECDSA signature over `SHA256(authData || SHA256(body))`, checks `rpIdHash`, and requires `counter > storedCounter` (replay defense), then persists the new counter.

For GET requests there is no body, so the signed client data is a canonical string: the request path plus a timestamp header, with the timestamp required to be within a few minutes of now. This keeps assertions from being replayable indefinitely on read routes.

### Storage: one SQLite Durable Object per device

`idFromName(keyId)` gives one DO instance per device. Each holds the public key and the counter. A DO is single-threaded, so read-compare-write on the counter is **atomic by construction** — exactly the linearizable primitive the replay counter needs. KV cannot do this (eventually consistent; a lost update silently destroys replay protection). Per-device sharding also means devices never contend with each other.

### Non-app callers

- **Unraid pipeline → tmdb-proxy:** sends `X-Rivulet-Server-Key`, checked against a Cloudflare secret. Set via `wrangler secret put`; never committed.
- **Simulator / dev builds:** same secret mechanism, distinct value (`X-Rivulet-Dev-Key`), so it can be rotated independently and revoked without touching the pipeline. It never ships in a release build (compiled out under `#if DEBUG`), so it cannot leak via the App Store binary.

### Failure behavior in the app

Attestation must never make the app worse than it is today. If attestation fails (network down, Apple's attest service unreachable, `isSupported == false`), the client:

- retries the one-time attestation with backoff, caching the failure briefly so it doesn't hammer;
- proceeds to make the request *unattested* rather than blocking the UI;
- and in `enforce` mode simply gets a 401, degrading exactly as an old build would (missing art / no trivia), never a crash or a hang.

This is deliberate: an attestation bug should cost us a locked-down endpoint, not a bricked app.

## Components

| Component | Location | Responsibility |
|---|---|---|
| `attest.ts` | shared, copied into both Workers | Pure verification: CBOR decode, DER/X.509 parse, chain walk, nonce check, assertion verify. No I/O. Unit-testable with vitest. |
| `DeviceRegistry` DO | `insights-api` (bound from both) | `{keyId → publicKey, counter}`, atomic counter bump. SQLite backend. |
| `guard.ts` | shared | Request middleware: extract headers, dispatch to DO, apply `ATTEST_MODE`, allow server/dev secret bypass. |
| `AppAttestClient.swift` | `Rivulet/Services/Security/` | Key lifecycle (Keychain-persisted `keyId`), one-time attest, per-request assertion, graceful degradation. |
| `seed.py` (edit) | `insights-pipeline` | Send `X-Rivulet-Server-Key` to tmdb-proxy. |

### A correctness trap, found while prototyping

**Apple signs the P-256 leaf with SHA-256, while the issuing intermediate key is P-384.** The signature hash must be read from each certificate's own `signatureAlgorithm` field, *not* inferred from the issuer's curve. A naive implementation infers SHA-384 from the P-384 issuer, fails leaf verification, and rejects every genuine device. This was caught in the prototype and the verifier reads the OID (`1.2.840.10045.4.3.2` = SHA-256, `...4.3.3` = SHA-384) explicitly.

## Error handling

| Condition | Response |
|---|---|
| Missing attestation headers, `observe` mode | Serve; bump the "unattested" counter |
| Missing attestation headers, `enforce` mode | `401 {"error":"attestation_required"}` |
| Unknown `keyId` | `401 {"error":"unknown_key"}` — client discards its Keychain keyId and re-attests once |
| Bad signature / nonce / rpIdHash | `401 {"error":"bad_assertion"}` |
| `counter <= storedCounter` | `401 {"error":"replay"}` |
| Challenge expired or unknown | `400 {"error":"bad_challenge"}` — client fetches a fresh one |
| Valid server/dev secret | Serve, bypassing attestation entirely |

Verification failures are never distinguished in detail to the client beyond these codes; there is nothing useful for an attacker to learn, and the app only needs to know "re-attest" vs "give up".

## Testing

- **Unit (vitest, both Workers):** fixture-driven. A generated Apple-shaped chain (P-384 root → P-384 intermediate → P-256 leaf with the nonce extension) plus a real CBOR attestation object. Cases: happy path; tampered `authData`; wrong challenge; wrong bundle/team in `rpIdHash`; `keyId` not matching the public key; leaf signed by a non-Apple root; replayed counter; counter equal to stored.
- **DO test:** two concurrent assertions with the same counter — exactly one must win.
- **Live negative test:** `curl` the deployed endpoints with no headers and with forged headers; both must 401 once in `enforce`.
- **Live positive test:** the app on a real Apple TV must attest once and then serve requests. **The simulator cannot test this** (`isSupported == false`); the sim exercises the dev-secret path instead.
- **Regression:** the pipeline's seed stage must still reach tmdb-proxy with its server secret.

## Out of scope

- Rate limiting per device (attestation alone removes the anonymous-abuse case; revisit only if a real device turns abusive).
- Apple's App Attest *receipt* / risk-metric API. The receipt is captured but not validated; it buys fraud signals we have no use for at this scale.
- Migrating `POST /report` beyond its current stub.
