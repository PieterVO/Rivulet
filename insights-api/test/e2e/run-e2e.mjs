/**
 * End-to-end check against a REAL running Worker with REAL Durable Objects.
 *
 * The unit tests stub the DO. This does not: it drives the actual HTTP surface
 * the app will drive, exercising the full loop —
 *
 *   1. GET  /attest/challenge      -> server-issued nonce
 *   2. POST /attest/verify         -> chain walk, nonce check, DO register
 *   3. signed request              -> assertion verified, counter bumped (ADMIT)
 *   4. REPLAY the same request     -> counter no longer strictly greater (REJECT)
 *   5. unsigned request            -> no attestation (REJECT in enforce)
 *   6. forged assertion            -> bad signature (REJECT)
 *   7. reused challenge            -> single-use (REJECT)
 *
 * We act as the Apple TV: mint a P-256 "Secure Enclave" key and an Apple-shaped
 * cert chain, and sign assertions with it. The Worker is told to trust our test
 * root via ATTEST_TEST_ROOT_PEM (never set in production).
 */
import { makeAttestation, makeAssertion } from "../fixtures/appattest.ts";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const BASE = process.env.E2E_BASE ?? "http://127.0.0.1:8791";
const APP_ID = "ABCDE12345.com.gstudios.rivulet";

// The CA the Worker was booted trusting (minted in phase 1). Our leaf chains up
// to it, exactly as a real device's leaf chains up to Apple's root.
const CA = JSON.parse(readFileSync(join(process.env.E2E_DIR, "ca.json"), "utf8"));

let pass = 0, fail = 0;
function check(name, ok, detail = "") {
  if (ok) { pass++; console.log(`  \x1b[32mPASS\x1b[0m ${name}`); }
  else { fail++; console.log(`  \x1b[31mFAIL\x1b[0m ${name} ${detail}`); }
}

const b64 = (u8) => Buffer.from(u8).toString("base64");

// ---- Act as the app: mint an SE key + Apple-shaped chain -------------------
// The attestation nonce binds the server's challenge, so the chain must be
// minted AFTER we fetch one. The chain carries its own fresh random root, which
// we hand to the Worker via ATTEST_TEST_ROOT_PEM (see below) — the Worker is
// booted by this same script, after the chain exists.
console.log("\nDevice: generating Secure Enclave key + attestation chain...");
const challengeRes = await fetch(`${BASE}/attest/challenge`);
const { challenge } = await challengeRes.json();
check("challenge issued", typeof challenge === "string" && challenge.length === 64, challenge);

const chain = await makeAttestation({ challenge, appId: APP_ID, ca: CA });

// ---- 2. Attest -------------------------------------------------------------
console.log("\nEnrollment:");
const verifyRes = await fetch(`${BASE}/attest/verify`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    keyId: b64(chain.keyId),
    attestationObject: b64(chain.attestationObject),
    challenge,
  }),
});
const verifyBody = await verifyRes.json();
check("device attests successfully", verifyRes.status === 200 && verifyBody.status === "attested",
  `${verifyRes.status} ${JSON.stringify(verifyBody)}`);

// ---- 7. The challenge is single-use ---------------------------------------
const replayChallenge = await fetch(`${BASE}/attest/verify`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    keyId: b64(chain.keyId),
    attestationObject: b64(chain.attestationObject),
    challenge, // same challenge again
  }),
});
check("REJECTS a reused challenge (single-use)", replayChallenge.status === 400,
  `got ${replayChallenge.status}`);

// ---- 3. A signed WRITE is admitted ----------------------------------------
console.log("\nSigned requests (the write path is always enforced):");
const body = Buffer.from(JSON.stringify({
  type: "movie", tmdbId: 27205, title: "Inception", year: 2010,
}));

async function signedWrite(counter) {
  const assertion = await makeAssertion(chain, new Uint8Array(body), counter);
  return fetch(`${BASE}/insights/request`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Rivulet-Key-Id": b64(chain.keyId),
      "X-Rivulet-Assertion": b64(assertion),
    },
    body,
  });
}

const r1 = await signedWrite(1);
check("ADMITS a genuine signed write", r1.status === 202 || r1.status === 200,
  `got ${r1.status} ${await r1.clone().text()}`);

// ---- 4. Replay is rejected -------------------------------------------------
// Re-send the SAME counter. The DO stored 1; a replay is not strictly greater.
const replay = await signedWrite(1);
const replayBody = await replay.json().catch(() => ({}));
check("REJECTS a replayed assertion (counter must strictly increase)",
  replay.status === 401 && replayBody.error === "replay",
  `got ${replay.status} ${JSON.stringify(replayBody)}`);

// ---- and a fresh counter still works (not permanently wedged) --------------
const r2 = await signedWrite(2);
check("ADMITS the next request with an advanced counter",
  r2.status === 202 || r2.status === 200, `got ${r2.status}`);

// ---- 5. Unsigned write is rejected ----------------------------------------
console.log("\nAttackers:");
const anon = await fetch(`${BASE}/insights/request`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body,
});
const anonBody = await anon.json().catch(() => ({}));
check("REJECTS an unsigned write (curl from the internet)",
  anon.status === 401 && anonBody.error === "attestation_required",
  `got ${anon.status} ${JSON.stringify(anonBody)}`);

// ---- 6. Forged assertion is rejected --------------------------------------
const forged = await fetch(`${BASE}/insights/request`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-Rivulet-Key-Id": b64(chain.keyId),
    "X-Rivulet-Assertion": b64(Buffer.from("garbage-not-a-real-assertion")),
  },
  body,
});
check("REJECTS a forged assertion", forged.status === 401, `got ${forged.status}`);

// ---- 6b. A DIFFERENT device's key can't sign for ours ---------------------
// Note this attacker has a FULLY VALID chain (same CA, real Apple-shaped certs).
// It is rejected purely because its key is not the one registered under our
// keyId — chain validity alone buys an attacker nothing.
const attacker = await makeAttestation({ challenge: "x", appId: APP_ID, ca: CA });
const stolenSig = await makeAssertion(attacker, new Uint8Array(body), 99);
const impersonate = await fetch(`${BASE}/insights/request`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-Rivulet-Key-Id": b64(chain.keyId),          // our keyId...
    "X-Rivulet-Assertion": b64(stolenSig),          // ...their signature
  },
  body,
});
check("REJECTS an assertion signed by an unregistered key",
  impersonate.status === 401, `got ${impersonate.status}`);

// ---- 6c. Body tampering ----------------------------------------------------
const tamperedBody = Buffer.from(JSON.stringify({
  type: "movie", tmdbId: 99999, title: "Something Else",
}));
const sigForOriginal = await makeAssertion(chain, new Uint8Array(body), 3);
const tampered = await fetch(`${BASE}/insights/request`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-Rivulet-Key-Id": b64(chain.keyId),
    "X-Rivulet-Assertion": b64(sigForOriginal),
  },
  body: tamperedBody,   // swapped payload, signature from the original
});
check("REJECTS a swapped body (signature binds the payload)",
  tampered.status === 401, `got ${tampered.status}`);

console.log(`\n${fail === 0 ? "\x1b[32m" : "\x1b[31m"}${pass} passed, ${fail} failed\x1b[0m\n`);
process.exit(fail === 0 ? 0 : 1);
