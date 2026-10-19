import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { decodeJwt } from 'jose';
import { getTestPool } from '../pg';
import { seedFixtures, clearFixtures, SITE_A, SITE_B, SCAN_A } from '../fixtures';
import { buildTestApp, tokenFor, deviceTokenFor, bearer, type TestApp } from './helpers';

const pool = getTestPool();
let t: TestApp;
let app: FastifyInstance;

const WARD_A = 'DEV-WA';
const WARD_B = 'DEV-WB';
const b64 = (s: string | Buffer) => Buffer.from(s).toString('base64');

async function post(url: string, body: unknown, token?: string, key: string = randomUUID()) {
  return app.inject({
    method: 'POST',
    url,
    headers: { ...bearer(token ?? (await tokenFor('clinician', SITE_A))), 'idempotency-key': key },
    payload: body as object,
  });
}

async function challenge(token?: string): Promise<string> {
  const r = await post('/v1/devices/challenge', {}, token);
  expect(r.statusCode).toBe(200);
  return r.json().challenge;
}

async function attest(o: { keyId?: string; ward?: string; token?: string; ch?: string } = {}) {
  const ch = o.ch ?? (await challenge(o.token));
  return post('/v1/devices/attest', {
    key_id: o.keyId ?? `key-${randomUUID()}`,
    attestation: b64('attestation-object'),
    challenge: ch,
    ward_id: o.ward ?? WARD_A,
  }, o.token);
}

async function enrol(): Promise<string> {
  const r = await attest();
  expect(r.statusCode).toBe(201);
  return r.json().device_id;
}

async function assertDevice(deviceId: string, counter: number | null, token?: string) {
  const ch = await challenge(token);
  return post('/v1/devices/assert', {
    device_id: deviceId,
    assertion: b64(counter === null ? 'x' : String(counter)),
    challenge: ch,
  }, token);
}

const deviceRow = async (id: string) =>
  (await pool.query(
    `SELECT site_id, ward_id, app_attest_key_id, attest_public_key, assertion_counter::int AS counter, status, push_token
       FROM devices WHERE id = $1`, [id])).rows[0];

const auditRows = async (deviceId: string) =>
  (await pool.query(
    `SELECT event_type, patient_pseudonym, outcome FROM clinical_audit_log
      WHERE resource_type = 'device' AND resource_id = $1 ORDER BY id`, [deviceId])).rows;

beforeAll(async () => {
  await seedFixtures(pool);
  await pool.query(`INSERT INTO wards(id, site_id) VALUES ($1,$2),($3,$4) ON CONFLICT DO NOTHING`, [WARD_A, SITE_A, WARD_B, SITE_B]);
  t = await buildTestApp();
  app = t.app;
});
beforeEach(() => {
  t.fakes.appAttest.fail = false;
});
afterAll(async () => {
  await app.close();
  await clearFixtures(pool);
});

describe('POST /v1/devices/challenge', () => {
  it('admin/clinician get a 32-byte base64 challenge stored hashed with a 5-min TTL', async () => {
    for (const role of ['clinician', 'admin']) {
      const ch = await challenge(await tokenFor(role, SITE_A));
      const raw = Buffer.from(ch, 'base64');
      expect(raw.length).toBe(32);
      const row = (await pool.query(
        `SELECT issued_to, site_id, extract(epoch FROM expires_at - created_at)::int AS ttl
           FROM device_challenges WHERE challenge_hash = $1`,
        [createHash('sha256').update(raw).digest()])).rows[0];
      expect(row).toEqual({ issued_to: `rls-${role}`, site_id: SITE_A, ttl: 300 });
    }
  });

  it('nurse → 403; device token → 403; site-less admin → 403; no token → 401', async () => {
    expect((await post('/v1/devices/challenge', {}, await tokenFor('nurse_operator', SITE_A))).statusCode).toBe(403);
    expect((await post('/v1/devices/challenge', {}, await deviceTokenFor(randomUUID(), SITE_A))).statusCode).toBe(403);
    expect((await post('/v1/devices/challenge', {}, await tokenFor('admin'))).statusCode).toBe(403);
    const r = await app.inject({ method: 'POST', url: '/v1/devices/challenge', payload: {} });
    expect(r.statusCode).toBe(401);
  });

  it('unknown body field → 400', async () => {
    expect((await post('/v1/devices/challenge', { extra: 1 })).statusCode).toBe(400);
  });
});

describe('POST /v1/devices/attest', () => {
  it('challenge single use', async () => {
    const ch = await challenge();
    expect((await attest({ ch })).statusCode).toBe(201);
    const again = await attest({ ch });
    expect(again.statusCode).toBe(401);
    expect(again.json().error.code).toBe('DS_DEVICE_003');
  });

  it('challenge is consumed even when attestation verification fails', async () => {
    const ch = await challenge();
    t.fakes.appAttest.fail = true;
    const r = await attest({ ch });
    expect(r.statusCode).toBe(401);
    expect(r.json().error.code).toBe('DS_DEVICE_004');
    t.fakes.appAttest.fail = false;
    expect((await attest({ ch })).json().error.code).toBe('DS_DEVICE_003');
  });

  it('expired, unknown, or another user\'s challenge → 401 DS_DEVICE_003', async () => {
    const ch = await challenge();
    await pool.query(`UPDATE device_challenges SET expires_at = now() - interval '1 second' WHERE challenge_hash = $1`,
      [createHash('sha256').update(Buffer.from(ch, 'base64')).digest()]);
    expect((await attest({ ch })).json().error.code).toBe('DS_DEVICE_003');
    expect((await attest({ ch: randomBytes(32).toString('base64') })).json().error.code).toBe('DS_DEVICE_003');
    const other = await challenge(await tokenFor('clinician', SITE_A, { sub: 'other-clinician' }));
    const r = await attest({ ch: other });
    expect(r.statusCode).toBe(401);
    expect(r.json().error.code).toBe('DS_DEVICE_003');
  });

  it('attest stores key', async () => {
    const keyId = `key-${randomUUID()}`;
    const ch = await challenge();
    const r = await attest({ keyId, ch });
    expect(r.statusCode).toBe(201);
    const id = r.json().device_id;
    expect(Object.keys(r.json())).toEqual(['device_id']);
    expect(await deviceRow(id)).toEqual({
      site_id: SITE_A, ward_id: WARD_A, app_attest_key_id: keyId,
      attest_public_key: t.fakes.appAttest.publicKey, counter: 0, status: 'active', push_token: null,
    });
    const call = t.fakes.appAttest.attestations.at(-1)!;
    expect(call.keyId).toBe(keyId);
    expect(call.challenge.equals(Buffer.from(ch, 'base64'))).toBe(true);
    expect(call.attestationObject.toString()).toBe('attestation-object');
    expect(await auditRows(id)).toEqual([{ event_type: 'device_event', patient_pseudonym: 'n/a', outcome: 'device:attested' }]);
  });

  it('ward in another site or unknown ward → 404, and no device row', async () => {
    const keyId = `key-${randomUUID()}`;
    for (const ward of [WARD_B, 'NOPE']) {
      const r = await attest({ keyId, ward });
      expect(r.statusCode).toBe(404);
      expect(r.json().error.code).toBe('DS_NOT_FOUND');
    }
    expect((await pool.query('SELECT 1 FROM devices WHERE app_attest_key_id = $1', [keyId])).rowCount).toBe(0);
  });

  it('already-enrolled key_id → 409 DS_DEVICE_005', async () => {
    const keyId = `key-${randomUUID()}`;
    expect((await attest({ keyId })).statusCode).toBe(201);
    const r = await attest({ keyId });
    expect(r.statusCode).toBe(409);
    expect(r.json().error.code).toBe('DS_DEVICE_005');
  });

  it('nurse → 403; invalid base64 / unknown field → 400', async () => {
    expect((await attest({ token: await tokenFor('nurse_operator', SITE_A), ch: randomBytes(32).toString('base64') })).statusCode).toBe(403);
    const ch = await challenge();
    const bad = await post('/v1/devices/attest', { key_id: 'k', attestation: '%%%', challenge: ch, ward_id: WARD_A });
    expect(bad.statusCode).toBe(400);
    const extra = await post('/v1/devices/attest', { key_id: 'k', attestation: b64('a'), challenge: ch, ward_id: WARD_A, x: 1 });
    expect(extra.statusCode).toBe(400);
  });
});

describe('POST /v1/devices/assert', () => {
  it('assert issues 24h device token', async () => {
    const id = await enrol();
    const r = await assertDevice(id, 1);
    expect(r.statusCode).toBe(200);
    expect(r.json().expires_in).toBe(86400);
    const tok = r.json().device_token;
    const p = decodeJwt(tok);
    expect(p.aud).toBe('device-upload');
    expect(p.exp! - p.iat!).toBe(86400);
    expect(await t.deps.deviceTokenSigner.verify(tok)).toEqual({ device_id: id, site_id: SITE_A });
    expect((await deviceRow(id)).counter).toBe(1);

    // verifier got the stored key, the previous counter, and clientDataHash = sha256(challenge)
    const call = t.fakes.appAttest.assertions.at(-1)!;
    expect(call.publicKey.equals(t.fakes.appAttest.publicKey)).toBe(true);
    expect(call.prevCounter).toBe(0);
    expect(call.clientDataHash.length).toBe(32);

    // the token works on a device route
    const g = await app.inject({ method: 'GET', url: `/v1/scans/${SCAN_A}`, headers: bearer(tok) });
    expect(g.statusCode).toBe(200);
    expect((await auditRows(id)).map((x) => x.outcome)).toEqual(['device:attested', 'device:asserted']);
  });

  it('replayed counter → 401 DS_DEVICE_002', async () => {
    const id = await enrol();
    expect((await assertDevice(id, 5)).statusCode).toBe(200);
    for (const n of [5, 3, 0]) {
      const r = await assertDevice(id, n);
      expect(r.statusCode).toBe(401);
      expect(r.json().error.code).toBe('DS_DEVICE_002');
    }
    expect((await deviceRow(id)).counter).toBe(5);
    expect((await assertDevice(id, 6)).statusCode).toBe(200);
    expect((await deviceRow(id)).counter).toBe(6);
  });

  it('assertion verification failure → 401 DS_DEVICE_004, counter unchanged', async () => {
    const id = await enrol();
    const ch = await challenge();
    t.fakes.appAttest.fail = true;
    const r = await post('/v1/devices/assert', { device_id: id, assertion: b64('9'), challenge: ch });
    expect(r.statusCode).toBe(401);
    expect(r.json().error.code).toBe('DS_DEVICE_004');
    expect((await deviceRow(id)).counter).toBe(0);
  });

  it('revoked device → 401 DS_DEVICE_001 (assert, and an already-issued token on GET /v1/scans/:id)', async () => {
    const id = await enrol();
    const tok = (await assertDevice(id, 1)).json().device_token;
    await pool.query(`UPDATE devices SET status = 'revoked' WHERE id = $1`, [id]);
    const r = await assertDevice(id, 2);
    expect(r.statusCode).toBe(401);
    expect(r.json().error.code).toBe('DS_DEVICE_001');
    const g = await app.inject({ method: 'GET', url: `/v1/scans/${SCAN_A}`, headers: bearer(tok) });
    expect(g.statusCode).toBe(401);
    expect(g.json().error.code).toBe('DS_DEVICE_001');
  });

  it('device of another site or unknown device → 404', async () => {
    const id = await enrol();
    const siteB = await tokenFor('clinician', SITE_B, { sub: 'clin-b' });
    expect((await assertDevice(id, 1, siteB)).statusCode).toBe(404);
    expect((await assertDevice(randomUUID(), 1)).statusCode).toBe(404);
    expect((await deviceRow(id)).counter).toBe(0);
  });

  it('rejected assertions (replay, verification failure, revoked) are audited', async () => {
    const id = await enrol();
    expect((await assertDevice(id, 3)).statusCode).toBe(200);
    expect((await assertDevice(id, 3)).statusCode).toBe(401);
    t.fakes.appAttest.fail = true;
    expect((await assertDevice(id, 4)).statusCode).toBe(401);
    t.fakes.appAttest.fail = false;
    await pool.query(`UPDATE devices SET status = 'revoked' WHERE id = $1`, [id]);
    expect((await assertDevice(id, 5)).statusCode).toBe(401);
    const rows = (await pool.query(
      `SELECT outcome, justification, event_type, patient_pseudonym FROM clinical_audit_log
        WHERE resource_type = 'device' AND resource_id = $1 AND outcome = 'device:assert_rejected' ORDER BY id`, [id])).rows;
    expect(rows.map((r) => r.justification)).toEqual(['DS_DEVICE_002', 'DS_DEVICE_004', 'DS_DEVICE_001']);
    expect(rows.every((r) => r.event_type === 'device_event' && r.patient_pseudonym === 'n/a')).toBe(true);
  });

  it('two concurrent assertions with the same counter: exactly one token issued', async () => {
    const id = await enrol();
    const [c1, c2] = [await challenge(), await challenge()];
    const rs = await Promise.all([c1, c2].map((ch) =>
      post('/v1/devices/assert', { device_id: id, assertion: b64('7'), challenge: ch })));
    expect(rs.map((r) => r.statusCode).sort()).toEqual([200, 401]);
    expect(rs.find((r) => r.statusCode === 401)!.json().error.code).toBe('DS_DEVICE_002');
    expect((await deviceRow(id)).counter).toBe(7);
  });

  it('challenge single use on assert', async () => {
    const id = await enrol();
    const ch = await challenge();
    expect((await post('/v1/devices/assert', { device_id: id, assertion: b64('1'), challenge: ch })).statusCode).toBe(200);
    const r = await post('/v1/devices/assert', { device_id: id, assertion: b64('2'), challenge: ch });
    expect(r.json().error.code).toBe('DS_DEVICE_003');
  });
});

describe('POST /v1/devices/push-token', () => {
  const APNS = 'a'.repeat(64);

  it('device token stores its own push token (204) and audits', async () => {
    const id = await enrol();
    const tok = (await assertDevice(id, 1)).json().device_token;
    const r = await post('/v1/devices/push-token', { device_id: id, apns_token: APNS }, tok);
    expect(r.statusCode).toBe(204);
    expect((await deviceRow(id)).push_token).toBe(APNS);
    expect((await auditRows(id)).map((x) => x.outcome)).toContain('device:push_token_registered');
  });

  it('another device id → 404; user token → 403; bad token format → 400', async () => {
    const id = await enrol();
    const other = await enrol();
    const tok = (await assertDevice(id, 1)).json().device_token;
    const r = await post('/v1/devices/push-token', { device_id: other, apns_token: APNS }, tok);
    expect(r.statusCode).toBe(404);
    expect((await deviceRow(other)).push_token).toBeNull();
    expect((await post('/v1/devices/push-token', { device_id: id, apns_token: APNS })).statusCode).toBe(403);
    expect((await post('/v1/devices/push-token', { device_id: id, apns_token: 'not hex!' }, tok)).statusCode).toBe(400);
  });

  it('revoked device → 401 DS_DEVICE_001', async () => {
    const id = await enrol();
    const tok = (await assertDevice(id, 1)).json().device_token;
    await pool.query(`UPDATE devices SET status = 'revoked' WHERE id = $1`, [id]);
    const r = await post('/v1/devices/push-token', { device_id: id, apns_token: APNS }, tok);
    expect(r.statusCode).toBe(401);
    expect(r.json().error.code).toBe('DS_DEVICE_001');
  });
});

describe('idempotency storage of /assert', () => {
  it('a successful assert leaves no device token in idempotency_keys', async () => {
    const id = await enrol();
    const r = await assertDevice(id, 1);
    expect(r.statusCode).toBe(200);
    const tok = r.json().device_token;
    const n = (await pool.query(
      `SELECT count(*)::int AS n FROM idempotency_keys
        WHERE response::text LIKE '%device_token%' OR strpos(coalesce(response::text, ''), $1) > 0`, [tok])).rows[0].n;
    expect(n).toBe(0);
  });
});

describe('device token renewal (no user token)', () => {
  const renewalChallenge = (deviceId: string) =>
    app.inject({ method: 'POST', url: `/v1/devices/${deviceId}/renewal-challenge`, payload: {} });
  const anonAssert = (deviceId: string, counter: number, ch: string) =>
    app.inject({ method: 'POST', url: '/v1/devices/assert', payload: { device_id: deviceId, assertion: b64(String(counter)), challenge: ch } });
  const renewRows = async (deviceId: string) =>
    (await pool.query(
      `SELECT purpose, device_id, extract(epoch FROM expires_at - created_at)::int AS ttl
         FROM device_challenges WHERE device_id = $1`, [deviceId])).rows;

  it('unauthenticated renewal-challenge then assert issues a token; audited with the device as actor', async () => {
    const id = await enrol();
    const c = await renewalChallenge(id);
    expect(c.statusCode).toBe(200);
    expect(Buffer.from(c.json().challenge, 'base64').length).toBe(32);
    expect(await renewRows(id)).toEqual([{ purpose: 'renew', device_id: id, ttl: 300 }]);
    const r = await anonAssert(id, 1, c.json().challenge);
    expect(r.statusCode).toBe(200);
    expect(r.json().expires_in).toBe(86400);
    expect(await t.deps.deviceTokenSigner.verify(r.json().device_token)).toEqual({ device_id: id, site_id: SITE_A });
    expect((await deviceRow(id)).counter).toBe(1);
    const a = (await pool.query(
      `SELECT event_type, actor_role, actor_id_hash, patient_pseudonym FROM clinical_audit_log
        WHERE resource_type = 'device' AND resource_id = $1 AND outcome = 'device:renewed'`, [id])).rows;
    expect(a).toEqual([{ event_type: 'device_event', actor_role: 'device',
      actor_id_hash: createHash('sha256').update(id).digest('hex'), patient_pseudonym: 'n/a' }]);
    // single use
    expect((await anonAssert(id, 2, c.json().challenge)).json().error.code).toBe('DS_DEVICE_003');
  });

  it('a renew challenge for device A cannot be used for device B', async () => {
    const a = await enrol();
    const b = await enrol();
    const ch = (await renewalChallenge(a)).json().challenge;
    const r = await anonAssert(b, 1, ch);
    expect(r.statusCode).toBe(401);
    expect(r.json().error.code).toBe('DS_DEVICE_003');
    expect((await deviceRow(b)).counter).toBe(0);
  });

  it('revoked or unknown device → 404 DS_NOT_FOUND on renewal-challenge', async () => {
    const id = await enrol();
    await pool.query(`UPDATE devices SET status = 'revoked' WHERE id = $1`, [id]);
    for (const d of [id, randomUUID()]) {
      const r = await renewalChallenge(d);
      expect(r.statusCode).toBe(404);
      expect(r.json().error.code).toBe('DS_NOT_FOUND');
    }
    expect(await renewRows(id)).toEqual([]);
  });

  it('more than 5 outstanding renew challenges per device → 429 DS_RATE_001', async () => {
    const id = await enrol();
    for (let i = 0; i < 5; i++) expect((await renewalChallenge(id)).statusCode).toBe(200);
    const r = await renewalChallenge(id);
    expect(r.statusCode).toBe(429);
    expect(r.json().error.code).toBe('DS_RATE_001');
    // expired ones do not count
    await pool.query(`UPDATE device_challenges SET expires_at = now() - interval '1 second' WHERE device_id = $1`, [id]);
    expect((await renewalChallenge(id)).statusCode).toBe(200);
  });

  it('attest-purpose challenge cannot be used for renew, and a renew challenge cannot be used to attest or user-assert', async () => {
    const id = await enrol();
    const userCh = await challenge();
    expect((await anonAssert(id, 1, userCh)).json().error.code).toBe('DS_DEVICE_003');
    const renewCh = (await renewalChallenge(id)).json().challenge;
    expect((await attest({ ch: renewCh })).json().error.code).toBe('DS_DEVICE_003');
    const renewCh2 = (await renewalChallenge(id)).json().challenge;
    const viaUser = await post('/v1/devices/assert', { device_id: id, assertion: b64('1'), challenge: renewCh2 });
    expect(viaUser.json().error.code).toBe('DS_DEVICE_003');
    expect((await deviceRow(id)).counter).toBe(0);
  });

  it('renewal with a replayed counter → 401 DS_DEVICE_002; invalid bearer on assert → 401 (no silent fallback)', async () => {
    const id = await enrol();
    expect((await anonAssert(id, 4, (await renewalChallenge(id)).json().challenge)).statusCode).toBe(200);
    const r = await anonAssert(id, 4, (await renewalChallenge(id)).json().challenge);
    expect(r.statusCode).toBe(401);
    expect(r.json().error.code).toBe('DS_DEVICE_002');
    const bad = await app.inject({ method: 'POST', url: '/v1/devices/assert', headers: { authorization: 'Bearer junk' },
      payload: { device_id: id, assertion: b64('5'), challenge: (await renewalChallenge(id)).json().challenge } });
    expect(bad.statusCode).toBe(401);
    expect(bad.json().error.code).toBe('DS_AUTH_001');
  });

  it('nurse token on assert → 403 (enrolment-side user flow stays admin/clinician)', async () => {
    const id = await enrol();
    const r = await post('/v1/devices/assert', { device_id: id, assertion: b64('1'), challenge: randomBytes(32).toString('base64') },
      await tokenFor('nurse_operator', SITE_A));
    expect(r.statusCode).toBe(403);
  });
});
