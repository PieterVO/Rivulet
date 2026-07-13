import { describe, it, expect } from "vitest";
import { guard, canonicalGetClientData, HDR_KEY_ID, HDR_ASSERTION, HDR_TIMESTAMP, HDR_SERVER_KEY, HDR_DEV_KEY, type GuardEnv } from "../src/guard";

/**
 * The guard's DO dependency is stubbed: the DO's own crypto is covered in
 * attest.test.ts. What we pin here is the POLICY — who gets in, who doesn't,
 * and how observe vs enforce differ.
 */
function envWith(over: Partial<GuardEnv> & { assertResult?: any } = {}): GuardEnv {
  const assertResult = over.assertResult ?? { ok: true };
  return {
    DEVICE_REGISTRY: {
      idFromName: (n: string) => n,
      get: () => ({ assertAndBump: async () => assertResult }),
    } as any,
    APP_ID: "ABCDE12345.com.gstudios.rivulet",
    ATTEST_MODE: over.ATTEST_MODE,
    SERVER_KEY: over.SERVER_KEY,
    DEV_KEY: over.DEV_KEY,
  };
}

const req = (headers: Record<string, string> = {}) =>
  new Request("https://x.dev/insights/movie/27205", { headers });
const url = new URL("https://x.dev/insights/movie/27205");

describe("guard — grace period (observe)", () => {
  it("serves an OLD BUILD that sends no attestation headers", async () => {
    // The entire point of the grace period: shipped apps keep working.
    const r = await guard(req(), url, envWith({ ATTEST_MODE: "observe" }), null);
    expect(r).toMatchObject({ allow: true, attested: false, via: "unattested" });
  });

  it("still REJECTS a forged assertion, even in observe mode", async () => {
    // Observe forgives ABSENCE, never a bad signature — otherwise sending
    // garbage headers would be a permanent free bypass.
    const r = await guard(
      req({ [HDR_KEY_ID]: "k", [HDR_ASSERTION]: "AAAA", [HDR_TIMESTAMP]: String(Date.now()) }),
      url,
      envWith({ ATTEST_MODE: "observe", assertResult: { ok: false, error: "bad_signature" } }),
      null,
    );
    expect(r).toMatchObject({ allow: false, status: 401, error: "bad_signature" });
  });
});

describe("guard — enforce", () => {
  it("REJECTS a caller with no attestation (curl from the internet)", async () => {
    const r = await guard(req(), url, envWith({ ATTEST_MODE: "enforce" }), null);
    expect(r).toMatchObject({ allow: false, status: 401, error: "attestation_required" });
  });

  it("admits a genuine assertion", async () => {
    const r = await guard(
      req({ [HDR_KEY_ID]: "k", [HDR_ASSERTION]: "AAAA", [HDR_TIMESTAMP]: String(Date.now()) }),
      url,
      envWith({ ATTEST_MODE: "enforce", assertResult: { ok: true } }),
      null,
    );
    expect(r).toMatchObject({ allow: true, attested: true, via: "assertion" });
  });

  it("rejects an unknown keyId (device never attested)", async () => {
    const r = await guard(
      req({ [HDR_KEY_ID]: "k", [HDR_ASSERTION]: "AAAA", [HDR_TIMESTAMP]: String(Date.now()) }),
      url,
      envWith({ ATTEST_MODE: "enforce", assertResult: { ok: false, error: "unknown_key" } }),
      null,
    );
    expect(r).toMatchObject({ allow: false, error: "unknown_key" });
  });

  it("rejects a stale GET assertion (replay window closed)", async () => {
    const old = String(Date.now() - 10 * 60 * 1000);
    const r = await guard(
      req({ [HDR_KEY_ID]: "k", [HDR_ASSERTION]: "AAAA", [HDR_TIMESTAMP]: old }),
      url,
      envWith({ ATTEST_MODE: "enforce" }),
      null,
    );
    expect(r).toMatchObject({ allow: false, error: "stale_timestamp" });
  });
});

describe("guard — machine callers", () => {
  it("admits the Unraid pipeline via the server secret", async () => {
    const r = await guard(
      req({ [HDR_SERVER_KEY]: "s3cret" }),
      url,
      envWith({ ATTEST_MODE: "enforce", SERVER_KEY: "s3cret" }),
      null,
    );
    expect(r).toMatchObject({ allow: true, via: "server_key" });
  });

  it("admits the Simulator via the dev secret", async () => {
    const r = await guard(
      req({ [HDR_DEV_KEY]: "devs3cret" }),
      url,
      envWith({ ATTEST_MODE: "enforce", DEV_KEY: "devs3cret" }),
      null,
    );
    expect(r).toMatchObject({ allow: true, via: "dev_key" });
  });

  it("REJECTS a wrong server secret outright (never falls through to grace)", async () => {
    // A guessed secret must not be quietly served just because we're in observe.
    const r = await guard(
      req({ [HDR_SERVER_KEY]: "guess" }),
      url,
      envWith({ ATTEST_MODE: "observe", SERVER_KEY: "s3cret" }),
      null,
    );
    expect(r).toMatchObject({ allow: false, status: 401, error: "bad_key" });
  });
});

describe("guard — body binding", () => {
  it("signs over the POST body when present", async () => {
    // Proves we pass the exact body bytes through as clientData, so a swapped
    // payload can't ride an assertion minted for a different one.
    let seen: number[] | null = null;
    const env = {
      DEVICE_REGISTRY: {
        idFromName: (n: string) => n,
        get: () => ({
          assertAndBump: async (i: any) => { seen = i.clientData; return { ok: true }; },
        }),
      },
      APP_ID: "ABCDE12345.com.gstudios.rivulet",
      ATTEST_MODE: "enforce",
    } as any;

    const body = new TextEncoder().encode('{"tmdbId":27205}');
    const r = await guard(
      new Request("https://x.dev/insights/request", {
        method: "POST",
        headers: { [HDR_KEY_ID]: "k", [HDR_ASSERTION]: "AAAA" },
        body,
      }),
      new URL("https://x.dev/insights/request"),
      env,
      body,
    );
    expect(r).toMatchObject({ allow: true, via: "assertion" });
    expect(new Uint8Array(seen!)).toEqual(body);
  });

  it("canonical GET client data binds path, query, and timestamp", async () => {
    const d = canonicalGetClientData(new URL("https://x.dev/tmdb/details/27205?type=movie"), "123");
    expect(new TextDecoder().decode(d)).toBe("/tmdb/details/27205?type=movie\n123");
  });
});
