/**
 * Phase 1 of the e2e: mint the CA (root + intermediate) and write it to disk.
 *
 * Split out because of an ordering constraint: the Worker must BOOT trusting a
 * root, but the attestation nonce binds a challenge that only the RUNNING
 * Worker can issue. The CA doesn't depend on the challenge, so it can be minted
 * first; the leaf (which carries the nonce) is minted later by the harness.
 */
import { makeCA } from "../fixtures/appattest.ts";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.argv[2];
if (!dir) {
  console.error("usage: mint-chain.mjs <outdir>");
  process.exit(1);
}

const ca = await makeCA();
writeFileSync(join(dir, "root.pem"), ca.rootPem);
writeFileSync(join(dir, "ca.json"), JSON.stringify(ca));
console.log("minted CA ->", dir);
