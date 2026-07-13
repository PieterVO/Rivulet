/**
 * DeviceRegistry — one SQLite-backed Durable Object per attested device.
 *
 * Holds {publicKey, counter} for a single App Attest keyId. Addressed by
 * idFromName(keyId), so each device gets its own instance and devices never
 * contend with each other.
 *
 * The DO is the ONLY place the assertion counter can live: a Durable Object is
 * single-threaded, so read-compare-write is atomic by construction. That
 * atomicity IS the replay defense. KV cannot do this — it is eventually
 * consistent, and two racing assertions could both read the same stored
 * counter, both pass, and silently destroy replay protection.
 *
 * SQLite backend (`new_sqlite_classes`) is free-plan eligible; the older
 * key-value backend is paid/legacy.
 */
import { DurableObject } from "cloudflare:workers";
import { verifyAssertion, AttestError } from "./attest";

export interface RegisterInput {
  publicKeyRaw: number[]; // JSON-safe; Uint8Array doesn't survive structured RPC cleanly
}

export interface AssertInput {
  assertionObject: number[];
  clientData: number[];
  appId: string;
}

export class DeviceRegistry extends DurableObject {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx as any, env as any);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS device (
        id         INTEGER PRIMARY KEY CHECK (id = 1),
        public_key BLOB    NOT NULL,
        counter    INTEGER NOT NULL
      )
    `);
  }

  /** Persist a freshly attested device key. Idempotent re-attest overwrites. */
  async register(input: RegisterInput): Promise<void> {
    const pk = new Uint8Array(input.publicKeyRaw);
    this.sql.exec(
      "INSERT INTO device (id, public_key, counter) VALUES (1, ?, 0) " +
      "ON CONFLICT(id) DO UPDATE SET public_key = excluded.public_key, counter = 0",
      pk,
    );
  }

  /** True once this device has attested. */
  async isRegistered(): Promise<boolean> {
    return [...this.sql.exec("SELECT 1 FROM device WHERE id = 1")].length > 0;
  }

  /**
   * Verify an assertion and advance the counter, atomically.
   *
   * Returns an error string rather than throwing so the caller can map it to
   * a status code without a try/catch across the RPC boundary.
   */
  async assertAndBump(input: AssertInput): Promise<{ ok: true } | { ok: false; error: string }> {
    const rows = [...this.sql.exec<{ public_key: ArrayBuffer; counter: number }>(
      "SELECT public_key, counter FROM device WHERE id = 1",
    )];
    if (rows.length === 0) return { ok: false, error: "unknown_key" };

    const publicKeyRaw = new Uint8Array(rows[0].public_key);
    const storedCounter = rows[0].counter;

    try {
      const { counter } = await verifyAssertion({
        assertionObject: new Uint8Array(input.assertionObject),
        clientData: new Uint8Array(input.clientData),
        publicKeyRaw,
        appId: input.appId,
        storedCounter,
      });
      // Single-threaded DO: nothing can interleave between the check above and
      // this write, so the counter is monotonic and a replay cannot land.
      this.sql.exec("UPDATE device SET counter = ? WHERE id = 1", counter);
      return { ok: true };
    } catch (e) {
      const error = e instanceof AttestError ? e.message : "bad_assertion";
      return { ok: false, error };
    }
  }
}

/**
 * ChallengeStore — a single DO holding one-time attestation challenges.
 *
 * Challenges must be server-issued, single-use, and short-lived, otherwise an
 * attacker could replay a captured attestation. One shared instance is fine:
 * attestation happens once per device, so this is cold-path.
 */
export class ChallengeStore extends DurableObject {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx as any, env as any);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS challenge (
        value      TEXT PRIMARY KEY,
        expires_at INTEGER NOT NULL
      )
    `);
  }

  async issue(ttlSeconds: number): Promise<string> {
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    const value = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
    const expires = Date.now() + ttlSeconds * 1000;
    this.sql.exec("INSERT INTO challenge (value, expires_at) VALUES (?, ?)", value, expires);
    // Opportunistic GC — keeps the table from growing without a cron.
    this.sql.exec("DELETE FROM challenge WHERE expires_at < ?", Date.now());
    return value;
  }

  /** Consume a challenge. Returns false if unknown, already used, or expired. */
  async consume(value: string): Promise<boolean> {
    const rows = [...this.sql.exec<{ expires_at: number }>(
      "SELECT expires_at FROM challenge WHERE value = ?", value,
    )];
    if (rows.length === 0) return false;
    this.sql.exec("DELETE FROM challenge WHERE value = ?", value); // single-use
    return rows[0].expires_at >= Date.now();
  }
}
