#!/usr/bin/env bash
#
# End-to-end: real workerd + real Durable Objects, driven over HTTP.
#
# Ordering problem: the Worker must trust the test root, but the root is minted
# by the harness. Solved by minting the chain FIRST (mint-chain.mjs writes the
# root + the device keypair to disk), THEN booting the Worker with that root,
# THEN replaying the saved device identity from the harness.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

PORT=8791
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$TMP"' EXIT

echo "1/3  minting the device identity (root CA + Secure Enclave key)..."
node --experimental-strip-types test/e2e/mint-chain.mjs "$TMP" >/dev/null

echo "2/3  booting the Worker (real workerd, real Durable Objects)..."
npx wrangler dev --port "$PORT" --local \
  --var APP_ID:ABCDE12345.com.gstudios.rivulet \
  --var ATTEST_MODE:enforce \
  --var "ATTEST_TEST_ROOT_PEM:$(cat "$TMP/root.pem")" \
  > "$TMP/wrangler.log" 2>&1 &

for _ in $(seq 1 30); do
  curl -sf -m 1 "http://127.0.0.1:$PORT/attest/challenge" >/dev/null 2>&1 && break
  sleep 1
done

echo "3/3  running the attack + happy-path suite..."
echo
E2E_BASE="http://127.0.0.1:$PORT" E2E_DIR="$TMP" \
  node --experimental-strip-types test/e2e/run-e2e.mjs
