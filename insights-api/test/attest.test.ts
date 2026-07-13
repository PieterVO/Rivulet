import { describe, it, expect } from "vitest";
import { verifyAttestation, verifyAssertion, AttestError } from "../src/attest";
import { makeAttestation, makeAssertion, TEST_APP_ID, type Chain } from "./fixtures/appattest";

const NOW = new Date("2026-07-13");
const body = (o: unknown) => new TextEncoder().encode(JSON.stringify(o));

/** Verify against the fixture's own root (tests mint their own trust anchor). */
function attestArgs(chain: Chain, over: Record<string, unknown> = {}) {
  return {
    attestationObject: chain.attestationObject,
    keyId: chain.keyId,
    challenge: chain.challenge,
    appId: chain.appId,
    rootPem: chain.rootPem,
    now: NOW,
    ...over,
  };
}

describe("verifyAttestation", () => {
  it("accepts a well-formed attestation and returns the SE public key", async () => {
    const chain = await makeAttestation();
    const r = await verifyAttestation(attestArgs(chain));
    expect(r.publicKeyRaw).toEqual(chain.publicKeyRaw);
    expect(r.publicKeyRaw.length).toBe(65); // uncompressed P-256 point
    expect(r.counter).toBe(0);
  });

  it("REJECTS a chain that does not terminate at Apple's real root", async () => {
    // The whole security property. The fixture is signed by a self-signed test
    // root; verifying it against the pinned Apple root must fail. If this ever
    // passes, anyone can mint their own chain and the lockdown is worthless.
    const chain = await makeAttestation();
    await expect(
      verifyAttestation(attestArgs(chain, { rootPem: undefined })), // -> Apple's pinned root
    ).rejects.toThrow(AttestError);
  });

  it("rejects a challenge the server did not issue", async () => {
    const chain = await makeAttestation();
    await expect(
      verifyAttestation(attestArgs(chain, { challenge: "some-other-challenge" })),
    ).rejects.toThrow(/nonce_mismatch/);
  });

  it("rejects a nonce that doesn't bind the challenge", async () => {
    const chain = await makeAttestation({ wrongNonce: true });
    await expect(verifyAttestation(attestArgs(chain))).rejects.toThrow(/nonce_mismatch/);
  });

  it("rejects tampered authData", async () => {
    const chain = await makeAttestation({ tamperAuthData: true });
    await expect(verifyAttestation(attestArgs(chain))).rejects.toThrow(AttestError);
  });

  it("rejects an attestation for a different app (fork with another bundle/team id)", async () => {
    const chain = await makeAttestation({ appId: "ZZZZZ99999.com.someone.fork" });
    // Fixture is internally consistent, but we verify it as OUR app id.
    await expect(
      verifyAttestation(attestArgs(chain, { appId: TEST_APP_ID })),
    ).rejects.toThrow(/rpid_mismatch/);
  });

  it("rejects a keyId that isn't the hash of the attested public key", async () => {
    const chain = await makeAttestation();
    const wrong = new Uint8Array(chain.keyId);
    wrong[0] ^= 0xff;
    await expect(
      verifyAttestation(attestArgs(chain, { keyId: wrong })),
    ).rejects.toThrow(/keyid_mismatch/);
  });

  it("rejects a fresh attestation whose counter is not zero", async () => {
    const chain = await makeAttestation({ badCounter: true });
    await expect(verifyAttestation(attestArgs(chain))).rejects.toThrow(/counter_not_zero/);
  });

  it("rejects an expired leaf certificate", async () => {
    const chain = await makeAttestation();
    await expect(
      verifyAttestation(attestArgs(chain, { now: new Date("2030-01-01") })),
    ).rejects.toThrow(/cert_expired/);
  });

  it("rejects a truncated / garbage attestation object", async () => {
    const chain = await makeAttestation();
    await expect(
      verifyAttestation(attestArgs(chain, {
        attestationObject: chain.attestationObject.slice(0, 40),
      })),
    ).rejects.toThrow(AttestError);
  });
});

describe("verifyAssertion", () => {
  async function attested() {
    const chain = await makeAttestation();
    const { publicKeyRaw } = await verifyAttestation(attestArgs(chain));
    return { chain, publicKeyRaw };
  }

  it("accepts a genuine assertion and returns the advanced counter", async () => {
    const { chain, publicKeyRaw } = await attested();
    const data = body({ type: "movie", tmdbId: 27205 });
    const assertion = await makeAssertion(chain, data, 1);

    const r = await verifyAssertion({
      assertionObject: assertion, clientData: data, publicKeyRaw,
      appId: chain.appId, storedCounter: 0,
    });
    expect(r.counter).toBe(1);
  });

  it("REJECTS a replayed assertion (counter must strictly increase)", async () => {
    const { chain, publicKeyRaw } = await attested();
    const data = body({ type: "movie", tmdbId: 27205 });
    const assertion = await makeAssertion(chain, data, 5);

    // First use at counter 5 is fine...
    await expect(verifyAssertion({
      assertionObject: assertion, clientData: data, publicKeyRaw,
      appId: chain.appId, storedCounter: 4,
    })).resolves.toEqual({ counter: 5 });

    // ...replaying the exact same bytes once 5 is stored must fail.
    await expect(verifyAssertion({
      assertionObject: assertion, clientData: data, publicKeyRaw,
      appId: chain.appId, storedCounter: 5,
    })).rejects.toThrow(/replay/);
  });

  it("rejects an assertion over a DIFFERENT body than the one signed", async () => {
    const { chain, publicKeyRaw } = await attested();
    const signed = body({ type: "movie", tmdbId: 27205 });
    const assertion = await makeAssertion(chain, signed, 1);

    // Attacker swaps the payload but keeps the signature.
    const swapped = body({ type: "movie", tmdbId: 99999 });
    await expect(verifyAssertion({
      assertionObject: assertion, clientData: swapped, publicKeyRaw,
      appId: chain.appId, storedCounter: 0,
    })).rejects.toThrow(/bad_signature/);
  });

  it("rejects an assertion signed by a key we never attested", async () => {
    const { chain } = await attested();
    const other = await makeAttestation();           // a different device
    const data = body({ type: "movie", tmdbId: 1 });
    const assertion = await makeAssertion(other, data, 1);

    // Verify the OTHER device's assertion against OUR stored public key.
    const { publicKeyRaw } = await verifyAttestation(attestArgs(chain));
    await expect(verifyAssertion({
      assertionObject: assertion, clientData: data, publicKeyRaw,
      appId: chain.appId, storedCounter: 0,
    })).rejects.toThrow(/bad_signature/);
  });

  it("rejects an assertion whose rpIdHash is another app", async () => {
    const { chain, publicKeyRaw } = await attested();
    const data = body({ ok: true });
    const assertion = await makeAssertion(chain, data, 1);
    await expect(verifyAssertion({
      assertionObject: assertion, clientData: data, publicKeyRaw,
      appId: "ZZZZZ99999.com.someone.fork", storedCounter: 0,
    })).rejects.toThrow(/rpid_mismatch/);
  });
});
