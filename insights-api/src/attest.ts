/**
 * Apple App Attest verification — pure WebCrypto, no Node APIs, workerd-safe.
 *
 * Two entry points:
 *   verifyAttestation() — once per device. Walks the X.509 chain to Apple's
 *     root, checks the nonce extension, derives keyId, returns the SE pubkey.
 *   verifyAssertion()   — per request. One ECDSA verify + counter compare.
 *
 * Measured cost under workerd: ~0.47ms attestation, ~0.04ms assertion. The
 * free plan allows 10ms CPU per invocation, so both sit far inside budget.
 *
 * We hand-parse the DER we need rather than pulling in an X.509 library:
 * the parse surface is small, and it keeps the Worker bundle tiny.
 */

/** Apple App Attest root CA. Pinned: the chain MUST terminate here. */
export const APPLE_ROOT_CA_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraNlKjpY4n63cga0jrcAtW5kwRsAw
-----END CERTIFICATE-----`;

const APPLE_NONCE_OID = "1.2.840.113635.100.8.2";
const OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2";
const OID_ECDSA_SHA384 = "1.2.840.10045.4.3.3";
const OID_P256 = "1.2.840.10045.3.1.7";
const OID_P384 = "1.3.132.0.34";

export class AttestError extends Error {}

// ---------------------------------------------------------------- DER reader

interface DerNode {
  tag: number;
  start: number;
  len: number;
  content: Uint8Array;
  end: number;
}

function readNode(buf: Uint8Array, off: number): DerNode {
  if (off >= buf.length) throw new AttestError("der_truncated");
  const tag = buf[off];
  let p = off + 1;
  let len = buf[p++];
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n > 4) throw new AttestError("der_length_too_large");
    len = 0;
    for (let i = 0; i < n; i++) len = (len << 8) | buf[p++];
  }
  const end = p + len;
  if (end > buf.length) throw new AttestError("der_overrun");
  return { tag, start: off, len, content: buf.subarray(p, end), end };
}

function* children(content: Uint8Array): Generator<DerNode> {
  let off = 0;
  while (off < content.length) {
    const n = readNode(content, off);
    yield n;
    off = n.end;
  }
}

function decodeOid(content: Uint8Array): string {
  const parts: number[] = [];
  let v = 0;
  for (let i = 0; i < content.length; i++) {
    const b = content[i];
    v = (v << 7) | (b & 0x7f);
    if (!(b & 0x80)) {
      parts.push(v);
      v = 0;
    }
  }
  const first = parts.shift() ?? 0;
  return [Math.floor(first / 40), first % 40, ...parts].join(".");
}

function decodeTime(node: DerNode): Date {
  const s = new TextDecoder().decode(node.content);
  const yLen = node.tag === 0x17 ? 2 : 4; // UTCTime vs GeneralizedTime
  let year = parseInt(s.slice(0, yLen), 10);
  if (yLen === 2) year += year < 50 ? 2000 : 1900;
  const num = (a: number, b: number) => parseInt(s.slice(a, b), 10);
  return new Date(Date.UTC(
    year,
    num(yLen, yLen + 2) - 1,
    num(yLen + 2, yLen + 4),
    num(yLen + 4, yLen + 6),
    num(yLen + 6, yLen + 8),
    num(yLen + 8, yLen + 10),
  ));
}

// ---------------------------------------------------------------- cert parse

interface ParsedCert {
  tbsRaw: Uint8Array;
  spkiRaw: Uint8Array;
  signature: Uint8Array;
  /**
   * Read from the cert's OWN signatureAlgorithm — NOT inferred from the
   * issuer's curve. Apple signs the P-256 leaf with ecdsa-with-SHA256 while
   * the issuing intermediate key is P-384; inferring the hash from the issuer
   * rejects every genuine device.
   */
  sigHash: "SHA-256" | "SHA-384";
  extensions: Map<string, Uint8Array>;
  notBefore: Date;
  notAfter: Date;
}

export function parseCert(der: Uint8Array): ParsedCert {
  const cert = readNode(der, 0);
  const kids = [...children(cert.content)];
  if (kids.length < 3) throw new AttestError("bad_cert");
  const tbs = kids[0];
  const sigAlg = kids[1];
  const sigBits = kids[2];

  const tbsRaw = cert.content.subarray(tbs.start, tbs.end);
  const signature = sigBits.content.subarray(1); // strip unused-bits byte

  const sigOid = decodeOid([...children(sigAlg.content)][0].content);
  let sigHash: "SHA-256" | "SHA-384";
  if (sigOid === OID_ECDSA_SHA256) sigHash = "SHA-256";
  else if (sigOid === OID_ECDSA_SHA384) sigHash = "SHA-384";
  else throw new AttestError("unsupported_sig_alg");

  const t = [...children(tbs.content)];
  let i = 0;
  if (t[i]?.tag === 0xa0) i++; // optional version [0]
  i += 3;                      // serial, sigalg, issuer
  const validity = t[i++];
  const [nb, na] = [...children(validity.content)];
  i++;                         // subject
  const spki = t[i++];
  const spkiRaw = tbs.content.subarray(spki.start, spki.end);

  const extensions = new Map<string, Uint8Array>();
  for (; i < t.length; i++) {
    if (t[i].tag !== 0xa3) continue; // [3] extensions
    const extSeq = readNode(t[i].content, 0);
    for (const ext of children(extSeq.content)) {
      const ec = [...children(ext.content)];
      extensions.set(decodeOid(ec[0].content), ec[ec.length - 1].content);
    }
  }

  return { tbsRaw, spkiRaw, signature, sigHash, extensions, notBefore: decodeTime(nb), notAfter: decodeTime(na) };
}

// ---------------------------------------------------------------- crypto glue

function concat(...arrs: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(arrs.reduce((n, a) => n + a.length, 0));
  let o = 0;
  for (const a of arrs) {
    out.set(a, o);
    o += a.length;
  }
  return out;
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data as BufferSource));
}

function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Curve OID lives in the SPKI's AlgorithmIdentifier parameters. */
function curveOf(spkiRaw: Uint8Array): "P-256" | "P-384" {
  const spki = readNode(spkiRaw, 0);
  const alg = [...children(spki.content)][0];
  const params = [...children(alg.content)][1];
  const oid = decodeOid(params.content);
  if (oid === OID_P256) return "P-256";
  if (oid === OID_P384) return "P-384";
  throw new AttestError("unsupported_curve");
}

/** Raw uncompressed EC point (65B for P-256) out of a SPKI. */
function publicPointOf(spkiRaw: Uint8Array): Uint8Array {
  const spki = readNode(spkiRaw, 0);
  const bitStr = [...children(spki.content)][1];
  return bitStr.content.subarray(1); // strip unused-bits byte
}

/** ECDSA DER sig -> raw r||s (what WebCrypto.verify wants). */
function derToRaw(der: Uint8Array, size: number): Uint8Array {
  const seq = readNode(der, 0);
  const [r, s] = [...children(seq.content)];
  const fix = (x: Uint8Array) => {
    let v = x;
    while (v.length > size && v[0] === 0) v = v.subarray(1);
    if (v.length > size) throw new AttestError("bad_signature_encoding");
    const out = new Uint8Array(size);
    out.set(v, size - v.length);
    return out;
  };
  return concat(fix(r.content), fix(s.content));
}

async function verifyCertSig(child: ParsedCert, issuerSpki: Uint8Array): Promise<boolean> {
  // Curve (and r||s width) from the ISSUER's key; hash from the CHILD's cert.
  const curve = curveOf(issuerSpki);
  const key = await crypto.subtle.importKey(
    "spki", issuerSpki as BufferSource,
    { name: "ECDSA", namedCurve: curve }, false, ["verify"],
  );
  const size = curve === "P-384" ? 48 : 32;
  return crypto.subtle.verify(
    { name: "ECDSA", hash: child.sigHash },
    key,
    derToRaw(child.signature, size) as BufferSource,
    child.tbsRaw as BufferSource,
  );
}

// ---------------------------------------------------------------- CBOR

/** Minimal CBOR decoder covering the shapes Apple emits. */
export function decodeCbor(buf: Uint8Array): any {
  let p = 0;
  function head(): [number, number] {
    if (p >= buf.length) throw new AttestError("cbor_truncated");
    const ib = buf[p++];
    const major = ib >> 5;
    const ai = ib & 0x1f;
    let val: number;
    if (ai < 24) val = ai;
    else if (ai === 24) val = buf[p++];
    else if (ai === 25) { val = (buf[p] << 8) | buf[p + 1]; p += 2; }
    else if (ai === 26) { val = ((buf[p] << 24) | (buf[p + 1] << 16) | (buf[p + 2] << 8) | buf[p + 3]) >>> 0; p += 4; }
    else if (ai === 27) {
      const hi = ((buf[p] << 24) | (buf[p + 1] << 16) | (buf[p + 2] << 8) | buf[p + 3]) >>> 0;
      const lo = ((buf[p + 4] << 24) | (buf[p + 5] << 16) | (buf[p + 6] << 8) | buf[p + 7]) >>> 0;
      if (hi !== 0) throw new AttestError("cbor_length_too_large");
      val = lo; p += 8;
    } else throw new AttestError("cbor_bad_length");
    return [major, val];
  }
  function value(depth: number): any {
    if (depth > 16) throw new AttestError("cbor_too_deep");
    const [major, val] = head();
    switch (major) {
      case 0: return val;
      case 1: return -1 - val;
      case 2: { const b = buf.subarray(p, p + val); p += val; return b; }
      case 3: { const s = new TextDecoder().decode(buf.subarray(p, p + val)); p += val; return s; }
      case 4: { const a: any[] = []; for (let i = 0; i < val; i++) a.push(value(depth + 1)); return a; }
      case 5: {
        const o: Record<string, any> = {};
        for (let i = 0; i < val; i++) { const k = value(depth + 1); o[String(k)] = value(depth + 1); }
        return o;
      }
      case 6: return value(depth + 1); // semantic tag: decode the tagged value
      case 7: return val === 21 ? true : val === 20 ? false : null;
      default: throw new AttestError("cbor_bad_major");
    }
  }
  return value(0);
}

// ---------------------------------------------------------------- authData

/** authData layout: rpIdHash(32) flags(1) counter(4) [aaguid(16) credIdLen(2) credId] */
function authCounter(a: Uint8Array): number {
  return ((a[33] << 24) | (a[34] << 16) | (a[35] << 8) | a[36]) >>> 0;
}

// ---------------------------------------------------------------- attestation

export interface AttestationInput {
  attestationObject: Uint8Array;
  keyId: Uint8Array;      // 32B, from the client
  challenge: string;      // the one-time challenge we issued
  appId: string;          // "TEAMID.bundle.id"
  now?: Date;
  /**
   * Trust anchor. Defaults to Apple's pinned root. Tests override it to mint
   * their own chains; production NEVER passes this, so the pin holds. A test
   * that pins the real Apple root against a self-signed chain must fail.
   */
  rootPem?: string;
}

export interface AttestationResult {
  publicKeyRaw: Uint8Array; // 65B uncompressed P-256 point — persist this
  counter: number;
}

export async function verifyAttestation(input: AttestationInput): Promise<AttestationResult> {
  const now = input.now ?? new Date();
  const att = decodeCbor(input.attestationObject);

  if (att?.fmt !== "apple-appattest") throw new AttestError("bad_fmt");
  const x5c = att.attStmt?.x5c;
  if (!Array.isArray(x5c) || x5c.length < 2) throw new AttestError("bad_x5c");
  const authData: Uint8Array = att.authData;
  if (!(authData instanceof Uint8Array) || authData.length < 55) throw new AttestError("bad_authdata");

  // 1. Chain: leaf <- intermediate <- pinned Apple root.
  const leaf = parseCert(x5c[0]);
  const inter = parseCert(x5c[1]);
  const root = parseCert(pemToDer(input.rootPem ?? APPLE_ROOT_CA_PEM));

  for (const c of [leaf, inter]) {
    if (now < c.notBefore || now > c.notAfter) throw new AttestError("cert_expired");
  }
  if (!(await verifyCertSig(inter, root.spkiRaw))) throw new AttestError("intermediate_not_trusted");
  if (!(await verifyCertSig(leaf, inter.spkiRaw))) throw new AttestError("leaf_not_trusted");

  // 2. nonce == SHA256(authData || SHA256(challenge)), in the leaf's Apple ext.
  const clientDataHash = await sha256(new TextEncoder().encode(input.challenge));
  const expectedNonce = await sha256(concat(authData, clientDataHash));
  const extRaw = leaf.extensions.get(APPLE_NONCE_OID);
  if (!extRaw) throw new AttestError("missing_nonce_ext");
  // ext payload: SEQUENCE { [1] { OCTET STRING nonce } }
  const oct = readNode(readNode(readNode(extRaw, 0).content, 0).content, 0);
  if (!equal(oct.content, expectedNonce)) throw new AttestError("nonce_mismatch");

  // 3. keyId == SHA256(leaf public key point).
  const publicKeyRaw = publicPointOf(leaf.spkiRaw);
  if (!equal(await sha256(publicKeyRaw), input.keyId)) throw new AttestError("keyid_mismatch");

  // 4. authData binds our app, starts at counter 0, and credId == keyId.
  const expectedRpId = await sha256(new TextEncoder().encode(input.appId));
  if (!equal(authData.subarray(0, 32), expectedRpId)) throw new AttestError("rpid_mismatch");
  if (authCounter(authData) !== 0) throw new AttestError("counter_not_zero");

  const credIdLen = (authData[53] << 8) | authData[54];
  if (!equal(authData.subarray(55, 55 + credIdLen), input.keyId)) throw new AttestError("credid_mismatch");

  return { publicKeyRaw, counter: 0 };
}

// ---------------------------------------------------------------- assertion

export interface AssertionInput {
  assertionObject: Uint8Array;
  clientData: Uint8Array;    // exact bytes the client signed
  publicKeyRaw: Uint8Array;  // stored at attestation time
  appId: string;
  storedCounter: number;
}

export async function verifyAssertion(input: AssertionInput): Promise<{ counter: number }> {
  const a = decodeCbor(input.assertionObject);
  const sig = a?.signature;
  const authData = a?.authenticatorData;
  if (!(sig instanceof Uint8Array) || !(authData instanceof Uint8Array) || authData.length < 37) {
    throw new AttestError("bad_assertion");
  }

  const nonce = await sha256(concat(authData, await sha256(input.clientData)));
  const key = await crypto.subtle.importKey(
    "raw", input.publicKeyRaw as BufferSource,
    { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"],
  );
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, key,
    derToRaw(sig, 32) as BufferSource, nonce as BufferSource,
  );
  if (!ok) throw new AttestError("bad_signature");

  const expectedRpId = await sha256(new TextEncoder().encode(input.appId));
  if (!equal(authData.subarray(0, 32), expectedRpId)) throw new AttestError("rpid_mismatch");

  // Strictly increasing: this is the replay defense.
  const counter = authCounter(authData);
  if (counter <= input.storedCounter) throw new AttestError("replay");

  return { counter };
}
