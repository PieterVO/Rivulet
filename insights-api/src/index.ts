/**
 * insights-api — serves Rivulet Insights trivia JSON from R2.
 *
 * Routes:
 *   GET /insights/movie/{tmdbId}                    → movie trivia JSON
 *   GET /insights/tv/{tmdbId}/{season}/{episode}    → episode trivia JSON
 *   GET /insights/suppressed                        → array of suppressed fact ids (short TTL)
 *   POST /report                                    → append a fact report (P2b; stubbed here)
 *
 * The fact JSON is immutable per generatedAt → long edge cache. The suppressed
 * list is the one dynamic read → short cache. R2 is bound natively (no S3 creds).
 */

export interface Env {
  INSIGHTS: R2Bucket;
}

const LONG_TTL = 60 * 60 * 24; // 24h edge cache for immutable fact JSON
const SHORT_TTL = 60 * 5; // 5m for the suppressed list

function cors(resp: Response): Response {
  const h = new Headers(resp.headers);
  h.set("Access-Control-Allow-Origin", "*");
  h.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  h.set("Access-Control-Allow-Headers", "Content-Type");
  return new Response(resp.body, { status: resp.status, headers: h });
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
