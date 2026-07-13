import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

/**
 * attest.ts and guard.ts are shared verbatim with insights-api. They are
 * security-critical crypto, and two copies that silently diverge is exactly
 * how a verifier ends up accidentally weakened in one Worker but not the other.
 *
 * insights-api is the source of truth (it also owns the Durable Objects). This
 * test fails the build if the copies drift, so a fix to one MUST be carried to
 * the other.
 */
const SHARED = ["attest.ts", "guard.ts"];

describe("shared attestation sources stay in sync with insights-api", () => {
  for (const file of SHARED) {
    it(`${file} is identical to the insights-api copy`, () => {
      const here = readFileSync(resolve(__dirname, `../src/${file}`), "utf8");
      const canonical = readFileSync(
        resolve(__dirname, `../../insights-api/src/${file}`),
        "utf8",
      );
      expect(
        here,
        `${file} has drifted from insights-api/src/${file}. ` +
          `insights-api is the source of truth: copy it over.`,
      ).toBe(canonical);
    });
  }
});
