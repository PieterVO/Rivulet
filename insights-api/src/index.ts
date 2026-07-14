/**
 * insights-api — serves Rivulet Insights trivia JSON from R2.
 *
 * Routes:
 *   GET  /insights/movie/{tmdbId}                    → movie trivia JSON
 *   GET  /insights/tv/{tmdbId}/{season}/{episode}    → episode trivia JSON
 *   GET  /insights/suppressed                        → array of suppressed fact ids (short TTL)
 *   POST /insights/request                           → on-demand generation request → R2 queue
 *   POST /report                                     → append a fact report (P2b; stubbed here)
 *
 * The fact JSON is immutable per generatedAt → long edge cache. The suppressed
 * list is the one dynamic read → short cache. R2 is bound natively (no S3 creds).
 */

import { validateRequest, workItemKey, publishedKey, queueObject } from "./request";
import { guard, b64ToBytes, type GuardEnv } from "./guard";
import { verifyAttestation, AttestError } from "./attest";

export { DeviceRegistry, ChallengeStore } from "./registry";

export interface Env extends GuardEnv {
  INSIGHTS: R2Bucket;
  CHALLENGES: DurableObjectNamespace;
}

/** Attestation challenges are single-use and short-lived. */
const CHALLENGE_TTL_SECONDS = 5 * 60;

const LONG_TTL = 60 * 60 * 24; // 24h edge cache for immutable fact JSON
const SHORT_TTL = 60 * 5; // 5m for the suppressed list

/**
 * The client is a native tvOS app, which does not perform CORS preflights and
 * does not need permissive CORS. `Access-Control-Allow-Origin: *` only ever
 * served to invite browser callers, so it is gone. Kept as a no-op passthrough
 * so call sites read unchanged.
 */
function cors(resp: Response): Response {
  return resp;
}

function json(body: unknown, status = 200, cacheSeconds = 0): Response {
  const h = new Headers({ "Content-Type": "application/json" });
  if (cacheSeconds > 0) h.set("Cache-Control", `public, max-age=${cacheSeconds}`);
  return new Response(JSON.stringify(body), { status, headers: h });
}

/** Serve an R2 object as JSON with edge caching, or a 404 JSON body. */
async function serveObject(env: Env, key: string, cacheSeconds: number): Promise<Response> {
  const obj = await env.INSIGHTS.get(key);
  if (obj === null) {
    // 404 is normal (uncovered title). Kept small and cacheable-short so a
    // miss doesn't hammer R2, but not long enough to mask a fresh publish.
    return json({ error: "not_found", key }, 404, 60);
  }
  const h = new Headers({
    "Content-Type": "application/json",
    "Cache-Control": `public, max-age=${cacheSeconds}`,
  });
  const etag = obj.httpEtag;
  if (etag) h.set("ETag", etag);
  return new Response(obj.body, { status: 200, headers: h });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }));

    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);

    // --- App Attest enrollment (unauthenticated by necessity: this IS how a
    // device proves itself for the first time). Both steps are cheap and the
    // challenge is single-use, so this is not an abuse lever.

    // GET /attest/challenge — a one-time nonce for attestKey().
    if (request.method === "GET" && parts[0] === "attest" && parts[1] === "challenge") {
      const store = env.CHALLENGES.get(env.CHALLENGES.idFromName("global"));
      const challenge = await (store as any).issue(CHALLENGE_TTL_SECONDS);
      return json({ challenge }, 200);
    }

    // POST /attest/verify — {keyId, attestationObject} -> register the device.
    if (request.method === "POST" && parts[0] === "attest" && parts[1] === "verify") {
      let payload: any;
      try {
        payload = await request.json();
      } catch {
        return json({ error: "bad_json" }, 400);
      }
      if (typeof payload?.keyId !== "string" || typeof payload?.attestationObject !== "string" ||
          typeof payload?.challenge !== "string") {
        return json({ error: "bad_request" }, 400);
      }

      const store = env.CHALLENGES.get(env.CHALLENGES.idFromName("global"));
      if (!(await (store as any).consume(payload.challenge))) {
        return json({ error: "bad_challenge" }, 400);
      }

      try {
        const { publicKeyRaw } = await verifyAttestation({
          attestationObject: b64ToBytes(payload.attestationObject),
          keyId: b64ToBytes(payload.keyId),
          challenge: payload.challenge,
          appId: env.APP_ID ?? "",
          // Trust anchor. UNSET IN PRODUCTION — wrangler.toml never defines
          // ATTEST_TEST_ROOT_PEM, so this is undefined and verifyAttestation
          // falls back to Apple's pinned root. It exists only so the local
          // end-to-end harness can mint a chain without a physical Apple TV.
          // Setting it on a deployed Worker would require account access, at
          // which point the attacker already owns everything.
          rootPem: env.ATTEST_TEST_ROOT_PEM,
        });
        const reg = env.DEVICE_REGISTRY.get(env.DEVICE_REGISTRY.idFromName(payload.keyId));
        await (reg as any).register({ publicKeyRaw: [...publicKeyRaw] });
        return json({ status: "attested" }, 200);
      } catch (e) {
        const error = e instanceof AttestError ? e.message : "attestation_failed";
        return json({ error }, 401);
      }
    }

    // --- Everything else is gated. Read the body ONCE: these exact bytes are
    // what the client signed, so they must be reused, not re-read.
    const rawBody = request.method === "POST"
      ? new Uint8Array(await request.arrayBuffer())
      : null;

    // The write path is enforced unconditionally — it is app-only (the Unraid
    // pipeline drains R2 directly and never calls this Worker), so no old
    // build and no server depends on it. It is also the only endpoint that
    // costs us money and feeds the LLM, so it does not get a grace period.
    const writePath = request.method === "POST" && parts[0] === "insights" && parts[1] === "request";
    const g = await guard(request, url, writePath ? { ...env, ATTEST_MODE: "enforce" } : env, rawBody);
    if (!g.allow) return json({ error: g.error }, g.status);

    // POST /insights/request — on-demand generation trigger. Validates the
    // camelCase app payload, short-circuits if already published, otherwise
    // writes a snake_case queue object to R2 for the pipeline's serve stage.
    if (writePath) {
      let body: unknown;
      try {
        body = JSON.parse(new TextDecoder().decode(rawBody!));
      } catch {
        return cors(json({ status: "invalid", reason: "bad_json" }, 400));
      }
      const v = validateRequest(body);
      if (!v.ok) return cors(json({ status: "invalid", reason: v.reason }, 400));
      const pub = publishedKey(v.req);
      if (await env.INSIGHTS.head(pub)) return cors(json({ status: "ready" }, 200));
      const key = `requests/pending/${workItemKey(v.req)}.json`;
      await env.INSIGHTS.put(key, JSON.stringify(queueObject(v.req, new Date().toISOString())), {
        httpMetadata: { contentType: "application/json" },
      });
      return cors(json({ status: "queued" }, 202));
    }

    // POST /report — P2b feedback sink. Stubbed 202 for now so the client can
    // wire the button ahead of the full report/suppress mechanism.
    if (request.method === "POST" && parts[0] === "report") {
      return cors(json({ status: "accepted" }, 202));
    }

    if (request.method !== "GET") {
      return cors(json({ error: "method_not_allowed" }, 405));
    }

    if (parts[0] !== "insights") return cors(json({ error: "not_found" }, 404));

    // GET /insights/suppressed
    if (parts[1] === "suppressed" && parts.length === 2) {
      // P2b computes this from report counts. Until then, empty list (nothing
      // suppressed). Short TTL so it can go live within minutes when populated.
      return cors(await serveOrEmpty(env, "suppressed/index.json", SHORT_TTL));
    }

    // GET /insights/movie/{tmdbId}
    if (parts[1] === "movie" && parts.length === 3 && /^\d+$/.test(parts[2])) {
      return cors(await serveObject(env, `insights/movie/${parts[2]}.json`, LONG_TTL));
    }

    // GET /insights/tv/{tmdbId}/show — show-level trivia (production/casting/
    // overall, not tied to one episode).
    if (parts[1] === "tv" && parts.length === 4 && /^\d+$/.test(parts[2]) && parts[3] === "show") {
      return cors(await serveObject(env, `insights/tv/${parts[2]}/show.json`, LONG_TTL));
    }

    // GET /insights/tv/{tmdbId}/{season}/{episode}
    if (
      parts[1] === "tv" &&
      parts.length === 5 &&
      /^\d+$/.test(parts[2]) &&
      /^\d+$/.test(parts[3]) &&
      /^\d+$/.test(parts[4])
    ) {
      const key = `insights/tv/${parts[2]}/${parts[3]}/${parts[4]}.json`;
      return cors(await serveObject(env, key, LONG_TTL));
    }

    return cors(json({ error: "not_found" }, 404));
  },
};

/** Serve an R2 object, or an empty JSON array if it doesn't exist yet. */
async function serveOrEmpty(env: Env, key: string, cacheSeconds: number): Promise<Response> {
  const obj = await env.INSIGHTS.get(key);
  if (obj === null) return json([], 200, cacheSeconds);
  return new Response(obj.body, {
    status: 200,
    headers: { "Content-Type": "application/json", "Cache-Control": `public, max-age=${cacheSeconds}` },
  });
}
