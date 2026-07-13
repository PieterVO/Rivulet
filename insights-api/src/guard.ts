/**
 * Attestation guard — the per-request gate shared by both Workers.
 *
 * Decides whether a caller is the genuine Rivulet app. Three ways in:
 *   1. A valid App Attest assertion (the app on real Apple hardware).
 *   2. A server secret (the Unraid pipeline — no Secure Enclave, so it cannot
 *      attest; the secret is safe here because that machine is ours and the
 *      secret never ships to a user).
 *   3. A dev secret (the Simulator, where isSupported == false). Compiled out
 *      of release builds, so it cannot leak via the App Store binary.
 *
 * Mode is an env var, so enforcement flips without a code change:
 *   "observe" — validate if present, serve regardless. Used during the
 *               grace period while old builds (which cannot attest) drain.
 *   "enforce" — reject anything unattested.
 */

export type AttestMode = "observe" | "enforce";

export interface GuardEnv {
  DEVICE_REGISTRY: DurableObjectNamespace;
  ATTEST_MODE?: string;
  APP_ID?: string;
  SERVER_KEY?: string;  // Unraid pipeline
  DEV_KEY?: string;     // Simulator / dev builds
}

export const HDR_KEY_ID = "X-Rivulet-Key-Id";
export const HDR_ASSERTION = "X-Rivulet-Assertion";
export const HDR_TIMESTAMP = "X-Rivulet-Timestamp";
export const HDR_SERVER_KEY = "X-Rivulet-Server-Key";
export const HDR_DEV_KEY = "X-Rivulet-Dev-Key";

/** GETs have no body, so the app signs this canonical string instead. */
export function canonicalGetClientData(url: URL, timestamp: string): Uint8Array {
  return new TextEncoder().encode(`${url.pathname}${url.search}\n${timestamp}`);
}

/** Replay window for GET assertions. The counter stops true replays; this
 *  bounds how long a captured assertion is even worth trying. */
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;

export type GuardResult =
  | { allow: true; attested: boolean; via: "assertion" | "server_key" | "dev_key" | "unattested" }
  | { allow: false; status: number; error: string };

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function mode(env: GuardEnv): AttestMode {
  return env.ATTEST_MODE === "enforce" ? "enforce" : "observe";
}

/**
 * Gate a request.
 *
 * `bodyBytes` must be the EXACT bytes the client signed. Callers that need the
 * body must read it once and pass it here, then reuse those bytes — re-reading
 * request.json() would consume the stream and could differ byte-for-byte.
 */
export async function guard(
  request: Request,
  url: URL,
  env: GuardEnv,
  bodyBytes: Uint8Array | null,
): Promise<GuardResult> {
  const enforcing = mode(env) === "enforce";

  // --- Machine callers (pipeline, simulator). Secrets, not attestation. ---
  const serverKey = request.headers.get(HDR_SERVER_KEY);
  if (serverKey && env.SERVER_KEY && constantTimeEqual(serverKey, env.SERVER_KEY)) {
    return { allow: true, attested: true, via: "server_key" };
  }
  const devKey = request.headers.get(HDR_DEV_KEY);
  if (devKey && env.DEV_KEY && constantTimeEqual(devKey, env.DEV_KEY)) {
    return { allow: true, attested: true, via: "dev_key" };
  }
  // A wrong secret is a deliberate forgery attempt — never fall through to
  // "unattested" and get served during the grace period.
  if ((serverKey && env.SERVER_KEY) || (devKey && env.DEV_KEY)) {
    return { allow: false, status: 401, error: "bad_key" };
  }

  // --- The app: App Attest assertion. ---
  const keyId = request.headers.get(HDR_KEY_ID);
  const assertion = request.headers.get(HDR_ASSERTION);

  if (!keyId || !assertion) {
    if (enforcing) return { allow: false, status: 401, error: "attestation_required" };
    return { allow: true, attested: false, via: "unattested" }; // grace period
  }

  let clientData: Uint8Array;
  if (bodyBytes && bodyBytes.length > 0) {
    clientData = bodyBytes;
  } else {
    const ts = request.headers.get(HDR_TIMESTAMP);
    if (!ts) {
      if (enforcing) return { allow: false, status: 401, error: "missing_timestamp" };
      return { allow: true, attested: false, via: "unattested" };
    }
    const skew = Math.abs(Date.now() - Number(ts));
    if (!Number.isFinite(skew) || skew > MAX_CLOCK_SKEW_MS) {
      if (enforcing) return { allow: false, status: 401, error: "stale_timestamp" };
      return { allow: true, attested: false, via: "unattested" };
    }
    clientData = canonicalGetClientData(url, ts);
  }

  let assertionBytes: Uint8Array;
  let keyIdBytes: string;
  try {
    assertionBytes = b64ToBytes(assertion);
    keyIdBytes = keyId;
  } catch {
    if (enforcing) return { allow: false, status: 401, error: "bad_assertion" };
    return { allow: true, attested: false, via: "unattested" };
  }

  const stub = env.DEVICE_REGISTRY.get(env.DEVICE_REGISTRY.idFromName(keyIdBytes));
  const result = await (stub as any).assertAndBump({
    assertionObject: [...assertionBytes],
    clientData: [...clientData],
    appId: env.APP_ID ?? "",
  });

  if (result.ok) return { allow: true, attested: true, via: "assertion" };

  // A PRESENTED assertion that fails is always rejected, even in observe mode:
  // observe exists to spare old builds that send nothing, not to forgive
  // forgeries. Otherwise "send a garbage header" would be a free bypass.
  const status = result.error === "unknown_key" ? 401 : 401;
  return { allow: false, status, error: result.error };
}

export function b64ToBytes(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
