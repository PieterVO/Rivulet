/**
 * Test-only generator for Apple-shaped App Attest payloads.
 *
 * Mirrors Apple's real structure so the verifier is exercised on the same
 * shapes it will see in production:
 *   P-384 root -> P-384 intermediate -> P-256 leaf carrying the nonce
 *   extension (OID 1.2.840.113635.100.8.2), wrapped in a CBOR attestation
 *   object. Crucially the leaf is signed with SHA-256 under a P-384 issuer,
 *   exactly as Apple does — that asymmetry is a real trap.
 *
 * Lets us mint both valid payloads and adversarial ones (foreign root,
 * tampered authData, replayed counter) without a physical Apple TV.
 */
import "reflect-metadata";
import * as x509 from "@peculiar/x509";
import { webcrypto } from "node:crypto";
import * as asn1js from "asn1js";

const crypto = webcrypto as unknown as Crypto;
x509.cryptoProvider.set(crypto as any);

export const TEST_APP_ID = "ABCDE12345.com.gstudios.rivulet";

const te = new TextEncoder();

function concat(...arrs: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(arrs.reduce((n, a) => n + a.length, 0));
  let o = 0;
  for (const a of arrs) { out.set(a, o); o += a.length; }
  return out;
}

async function sha256(b: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", b));
}

// ---- CBOR encoder (only what we need: map / bytes / text / array) ----
function cborHead(major: number, n: number): Uint8Array {
  if (n < 24) return new Uint8Array([(major << 5) | n]);
  if (n < 256) return new Uint8Array([(major << 5) | 24, n]);
  if (n < 65536) return new Uint8Array([(major << 5) | 25, n >> 8, n & 0xff]);
  return new Uint8Array([(major << 5) | 26, (n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff]);
}
const cborBytes = (b: Uint8Array) => concat(cborHead(2, b.length), b);
const cborText = (s: string) => { const b = te.encode(s); return concat(cborHead(3, b.length), b); };
const cborArray = (items: Uint8Array[]) => concat(cborHead(4, items.length), ...items);
function cborMap(entries: [string, Uint8Array][]): Uint8Array {
  return concat(cborHead(5, entries.length), ...entries.flatMap(([k, v]) => [cborText(k), v]));
}

/** ECDSA raw r||s (WebCrypto) -> DER, which is what Apple emits. */
function rawSigToDer(raw: Uint8Array): Uint8Array {
  const half = raw.length / 2;
  const trim = (x: Uint8Array) => {
    let i = 0;
    while (i < x.length - 1 && x[i] === 0) i++;
    let out = x.slice(i);
    if (out[0] & 0x80) out = concat(new Uint8Array([0]), out);
    return out;
  };
  const r = trim(raw.slice(0, half));
  const s = trim(raw.slice(half));
  return concat(
    new Uint8Array([0x30, r.length + s.length + 4]),
    new Uint8Array([0x02, r.length]), r,
    new Uint8Array([0x02, s.length]), s,
  );
}

export interface Chain {
  rootPem: string;
  attestationObject: Uint8Array;
  keyId: Uint8Array;
  challenge: string;
  appId: string;
  leafPrivateKey: CryptoKey;
  publicKeyRaw: Uint8Array;
  authData: Uint8Array;
}

export interface ChainOpts {
  challenge?: string;
  appId?: string;
  /** Emit an attestation whose counter is non-zero (must be rejected). */
  badCounter?: boolean;
  /** Corrupt authData after the nonce is computed (must be rejected). */
  tamperAuthData?: boolean;
  /** Put a wrong nonce in the leaf extension (must be rejected). */
  wrongNonce?: boolean;
  /**
   * Reuse a previously-minted CA (root + intermediate), instead of generating a
   * fresh random one.
   *
   * The e2e harness needs this: the Worker must be booted trusting a root, but
   * the attestation nonce binds a challenge only the RUNNING Worker can issue.
   * So the CA is minted first (it doesn't depend on the challenge), the Worker
   * boots trusting it, and the leaf — which carries the nonce — is minted after.
   */
  ca?: SavedCA;
}

/** A minted CA, serializable so it can outlive the process that made it. */
export interface SavedCA {
  rootPem: string;
  rootPrivateJwk: JsonWebKey;
  caPem: string;
  caPrivateJwk: JsonWebKey;
}

/** Mint just the CA (root + intermediate). Independent of any challenge. */
export async function makeCA(): Promise<SavedCA> {
  const rootKeys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-384" }, true, ["sign", "verify"]);
  const rootCert = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01",
    name: "CN=Apple App Attestation Root CA, O=Apple Inc.",
    notBefore: new Date("2020-03-18"),
    notAfter: new Date("2045-03-15"),
    signingAlgorithm: { name: "ECDSA", hash: "SHA-384" },
    keys: rootKeys as any,
    extensions: [new x509.BasicConstraintsExtension(true, 2, true)],
  });

  const caKeys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-384" }, true, ["sign", "verify"]);
  const caCert = await x509.X509CertificateGenerator.create({
    serialNumber: "02",
    subject: "CN=Apple App Attestation CA 1, O=Apple Inc.",
    issuer: rootCert.subject,
    notBefore: new Date("2020-03-18"),
    notAfter: new Date("2030-03-15"),
    signingAlgorithm: { name: "ECDSA", hash: "SHA-384" },
    publicKey: caKeys.publicKey as any,
    signingKey: rootKeys.privateKey as any,
    extensions: [new x509.BasicConstraintsExtension(true, 1, true)],
  });

  return {
    rootPem: rootCert.toString("pem"),
    rootPrivateJwk: await crypto.subtle.exportKey("jwk", rootKeys.privateKey),
    caPem: caCert.toString("pem"),
    caPrivateJwk: await crypto.subtle.exportKey("jwk", caKeys.privateKey),
  };
}

/**
 * Build a full attestation. `rootPem` is returned so a test can pin a
 * DIFFERENT root than Apple's and prove the chain check actually rejects it.
 */
export async function makeAttestation(opts: ChainOpts = {}): Promise<Chain> {
  const challenge = opts.challenge ?? "challenge-0001";
  const appId = opts.appId ?? TEST_APP_ID;

  // Reuse a pre-minted CA when given one (the e2e harness needs the root to
  // exist before the Worker boots); otherwise mint a throwaway CA.
  const savedCA = opts.ca ?? (await makeCA());
  const rootCert = new x509.X509Certificate(savedCA.rootPem);
  const caCert = new x509.X509Certificate(savedCA.caPem);
  const caPrivateKey = await crypto.subtle.importKey(
    "jwk", savedCA.caPrivateJwk,
    { name: "ECDSA", namedCurve: "P-384" }, false, ["sign"],
  );

  // Leaf = the Secure Enclave key.
  const leafKeys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const publicKeyRaw = new Uint8Array(await crypto.subtle.exportKey("raw", leafKeys.publicKey));
  const keyId = await sha256(publicKeyRaw); // keyId == SHA256(pubkey) == credId

  // authData = rpIdHash(32) | flags(1) | counter(4) | aaguid(16) | credIdLen(2) | credId
  const counterBytes = opts.badCounter
    ? new Uint8Array([0, 0, 0, 1])
    : new Uint8Array([0, 0, 0, 0]);
  let authData = concat(
    await sha256(te.encode(appId)),
    new Uint8Array([0x40]),
    counterBytes,
    te.encode("appattestdevelop"), // 16B aaguid
    new Uint8Array([0, 32]),
    keyId,
  );

  const nonceSource = opts.wrongNonce ? te.encode("not-the-challenge") : te.encode(challenge);
  const nonce = await sha256(concat(authData, await sha256(nonceSource)));

  // Apple's nonce extension: SEQUENCE { [1] EXPLICIT OCTET STRING nonce }
  const extDer = new Uint8Array(new asn1js.Sequence({
    value: [new asn1js.Constructed({
      idBlock: { tagClass: 3, tagNumber: 1 },
      value: [new asn1js.OctetString({ valueHex: nonce.slice().buffer })],
    })],
  }).toBER(false));

  const leafCert = await x509.X509CertificateGenerator.create({
    serialNumber: "03",
    subject: "CN=rivulet-device, O=ABCDE12345",
    issuer: caCert.subject,
    notBefore: new Date("2026-01-01"),
    notAfter: new Date("2027-06-01"),
    // SHA-256 leaf under a P-384 issuer — mirrors Apple, and is the trap.
    signingAlgorithm: { name: "ECDSA", hash: "SHA-256" },
    publicKey: leafKeys.publicKey as any,
    signingKey: caPrivateKey as any,
    extensions: [new x509.Extension("1.2.840.113635.100.8.2", false, extDer.slice().buffer)],
  });

  // Tamper AFTER the cert (and therefore the nonce) is fixed.
  if (opts.tamperAuthData) {
    authData = authData.slice();
    authData[10] ^= 0xff;
  }

  // Bulk receipt so CBOR decode cost is realistic; we don't validate it.
  const receipt = new Uint8Array(3800);

  const attestationObject = cborMap([
    ["fmt", cborText("apple-appattest")],
    ["attStmt", cborMap([
      ["x5c", cborArray([
        cborBytes(new Uint8Array(leafCert.rawData)),
        cborBytes(new Uint8Array(caCert.rawData)),
      ])],
      ["receipt", cborBytes(receipt)],
    ])],
    ["authData", cborBytes(authData)],
  ]);

  return {
    rootPem: savedCA.rootPem,
    attestationObject, keyId, challenge, appId,
    leafPrivateKey: leafKeys.privateKey,
    publicKeyRaw, authData,
  };
}

/** Sign an assertion with the leaf key, as the app's Secure Enclave would. */
export async function makeAssertion(
  chain: Chain,
  clientData: Uint8Array,
  counter: number,
): Promise<Uint8Array> {
  const authData = concat(
    await sha256(te.encode(chain.appId)),
    new Uint8Array([0x00]),
    new Uint8Array([(counter >>> 24) & 0xff, (counter >>> 16) & 0xff, (counter >>> 8) & 0xff, counter & 0xff]),
  );
  const nonce = await sha256(concat(authData, await sha256(clientData)));
  const raw = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, chain.leafPrivateKey, nonce,
  ));
  return cborMap([
    ["signature", cborBytes(rawSigToDer(raw))],
    ["authenticatorData", cborBytes(authData)],
  ]);
}
