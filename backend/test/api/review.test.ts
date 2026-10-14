import { randomUUID } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { getTestPool } from '../pg';
import { seedFixtures, clearFixtures, SITE_A, SITE_B, PATIENT_A, SCAN_A } from '../fixtures';
import { buildTestApp, tokenFor, bearer, type TestFakes } from './helpers';
import { reviewChallenge, canonicalJson } from '../../src/routes/review';
import { sha256Hex } from '../../src/audit';

const pool = getTestPool();
let app: FastifyInstance;
let fakes: TestFakes;

const WARD = 'RV-W1';
const DEVICE = '00000000-0000-4000-a000-0000000008d1';
const SCAN_NODEV = '00000000-0000-4000-b000-0000000008a1';
const SCAN_OTHER = '00000000-0000-4000-b000-0000000008a2'; // site B
const ASSERTION = { id: 'cred-1', response: { signature: 'sig' } };

async function setStatus(id: string, status: string) {
  // Superuser setup: walk the legal chain from the current status.
  const chain = ['capture_pending', 'quality_pending', 'quality_passed', 'feature_pending', 'feature_complete', 'review_pending'];
  const cur = (await pool.query('SELECT status::text AS s FROM scans WHERE id=$1', [id])).rows[0].s;
  if (cur !== 'capture_pending') {
    await pool.query('ALTER TABLE scans DISABLE TRIGGER USER');
    await pool.query('UPDATE scans SET status=$2 WHERE id=$1', [id, 'capture_pending']);
    await pool.query('ALTER TABLE scans ENABLE TRIGGER USER');
  }
  if (status === 'capture_pending') return;
  for (const s of chain.slice(1)) {
    await pool.query('UPDATE scans SET status=$2 WHERE id=$1', [id, s]);
    if (s === status) return;
  }
}

beforeAll(async () => {
  await seedFixtures(pool);
  await pool.query(`INSERT INTO wards(id, site_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`, [WARD, SITE_A]);
  await pool.query(`INSERT INTO devices(id, site_id, ward_id) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, [DEVICE, SITE_A, WARD]);
  await pool.query(
    `INSERT INTO scans(id,client_session_id,patient_id,site_id,captured_at,protocol_version)
     VALUES ($1,gen_random_uuid(),NULL,$3,now(),'p1'),($2,gen_random_uuid(),NULL,$4,now(),'p1')`,
    [SCAN_NODEV, SCAN_OTHER, SITE_A, SITE_B],
  );
  app = (await buildTestApp()).app;
});
afterAll(async () => {
  await pool.query('DELETE FROM features WHERE scan_id = ANY($1)', [[SCAN_A, SCAN_NODEV]]);
  await pool.query('DELETE FROM scan_reviews WHERE scan_id = ANY($1)', [[SCAN_A, SCAN_NODEV, SCAN_OTHER]]);
  await pool.query('DELETE FROM site_protocol_flags WHERE site_id = ANY($1)', [[SITE_A, SITE_B]]);
  await pool.query('UPDATE scans SET device_id=NULL WHERE id = ANY($1)', [[SCAN_A]]);
  await pool.query('DELETE FROM scans WHERE id = ANY($1)', [[SCAN_NODEV, SCAN_OTHER]]);
  await pool.query('DELETE FROM devices WHERE id=$1', [DEVICE]);
  await pool.query('DELETE FROM wards WHERE id=$1', [WARD]);
  await clearFixtures(pool);
  await app.close();
});
beforeEach(async () => {
  const t = await buildTestApp();
  await app.close();
  app = t.app;
  fakes = t.fakes;
  await pool.query('DELETE FROM scan_reviews WHERE scan_id = ANY($1)', [[SCAN_A, SCAN_NODEV]]);
  await pool.query('UPDATE scans SET device_id=NULL WHERE id=$1', [SCAN_A]);
  await setStatus(SCAN_A, 'review_pending');
  await setStatus(SCAN_NODEV, 'review_pending');
});

const review = async (id: string, body: Record<string, unknown>, role = 'clinician', site = SITE_A) =>
  app.inject({
    method: 'POST',
    url: `/v1/scans/${id}/review`,
    headers: { ...bearer(await tokenFor(role, site)), 'idempotency-key': randomUUID() },
    payload: { webauthn_assertion: ASSERTION, ...body },
  });
const status = async (id: string) => (await pool.query('SELECT status::text AS s FROM scans WHERE id=$1', [id])).rows[0].s;

describe('POST /v1/scans/:id/review', () => {
  it('nurse cannot review -> 403', async () => {
    const r = await review(SCAN_A, { action: 'confirm' }, 'nurse_operator');
    expect(r.statusCode).toBe(403);
    expect(await status(SCAN_A)).toBe('review_pending');
  });

  it('bad assertion -> 401 DS_AUTH_003, nothing changes', async () => {
    fakes.webauthn.result = false;
    const r = await review(SCAN_A, { action: 'confirm' });
    expect(r.statusCode).toBe(401);
    expect(r.json().error.code).toBe('DS_AUTH_003');
    expect(await status(SCAN_A)).toBe('review_pending');
    expect((await pool.query('SELECT 1 FROM scan_reviews WHERE scan_id=$1', [SCAN_A])).rowCount).toBe(0);
  });

  it('confirm moves review_pending->reviewed, stores hashes, passes the challenge, audits', async () => {
    const q = `SELECT count(*)::int AS n FROM clinical_audit_log WHERE outcome='review:confirm'`;
    const before = (await pool.query(q)).rows[0].n;
    const r = await review(SCAN_A, { action: 'confirm', note: 'ok' });
    expect(r.statusCode).toBe(201);
    expect(r.json().status).toBe('reviewed');
    expect(await status(SCAN_A)).toBe('reviewed');
    const row = (await pool.query('SELECT * FROM scan_reviews WHERE scan_id=$1', [SCAN_A])).rows[0];
    expect(row.reviewer_user_id).toBe('rls-clinician');
    expect(row.action).toBe('confirm');
    expect(row.webauthn_assertion_hash).toBe(sha256Hex(canonicalJson(ASSERTION)));
    const call = fakes.webauthn.calls[0];
    expect(call.expectedChallengeHash).toBe(reviewChallenge(SCAN_A, 'confirm', null, 'ok'));
    expect(call.userId).toBe('rls-clinician');
    expect((await pool.query(q)).rows[0].n).toBe(before + 1);
  });

  it('flag -> flagged, exclude -> excluded', async () => {
    expect((await review(SCAN_A, { action: 'flag', reason_code: 'artefact' })).json().status).toBe('flagged');
    await setStatus(SCAN_A, 'review_pending');
    expect((await review(SCAN_A, { action: 'exclude' })).json().status).toBe('excluded');
    expect(await status(SCAN_A)).toBe('excluded');
  });

  it('request_repeat -> flagged and pushes to the scan device', async () => {
    await pool.query('UPDATE scans SET device_id=$2 WHERE id=$1', [SCAN_A, DEVICE]);
    const r = await review(SCAN_A, { action: 'request_repeat' });
    expect(r.statusCode).toBe(201);
    expect(await status(SCAN_A)).toBe('flagged');
    expect(fakes.push.sent).toEqual([{ deviceId: DEVICE, payload: { type: 'repeat_requested', scan_id: SCAN_A } }]);
  });

  it('push failure still returns 201 with push failed and writes a device_event audit row', async () => {
    await pool.query('UPDATE scans SET device_id=$2 WHERE id=$1', [SCAN_A, DEVICE]);
    fakes.push.send = async () => {
      throw new Error('push down');
    };
    const r = await review(SCAN_A, { action: 'request_repeat' });
    expect(r.statusCode).toBe(201);
    expect(r.json().push).toBe('failed');
    expect(await status(SCAN_A)).toBe('flagged');
    const a = await pool.query(
      `SELECT event_type, patient_pseudonym FROM clinical_audit_log WHERE resource_id=$1 AND outcome='push:repeat_requested_failed'`,
      [SCAN_A],
    );
    expect(a.rows[0]).toEqual({ event_type: 'device_event', patient_pseudonym: 'ps-rls-a' });
  });

  it('push field is sent, or skipped for no device and other actions', async () => {
    await pool.query('UPDATE scans SET device_id=$2 WHERE id=$1', [SCAN_A, DEVICE]);
    expect((await review(SCAN_A, { action: 'request_repeat' })).json().push).toBe('sent');
    expect((await review(SCAN_NODEV, { action: 'request_repeat' })).json().push).toBe('skipped');
    await setStatus(SCAN_A, 'review_pending');
    expect((await review(SCAN_A, { action: 'confirm' })).json().push).toBe('skipped');
  });

  it('request_repeat with no device skips push and notes it in the audit', async () => {
    const r = await review(SCAN_NODEV, { action: 'request_repeat' });
    expect(r.statusCode).toBe(201);
    expect(fakes.push.sent).toEqual([]);
    const a = await pool.query(
      `SELECT justification FROM clinical_audit_log WHERE resource_id=$1 AND outcome='review:request_repeat'`,
      [SCAN_NODEV],
    );
    expect(a.rows[0].justification).toMatch(/no device/);
  });

  it('scan not in review_pending -> 409 DS_STATE_001', async () => {
    await setStatus(SCAN_A, 'feature_complete');
    const r = await review(SCAN_A, { action: 'confirm' });
    expect(r.statusCode).toBe(409);
    expect(r.json().error.code).toBe('DS_STATE_001');
  });

  it('other-site scan gives 404 and unknown field gives 400', async () => {
    expect((await review(SCAN_OTHER, { action: 'confirm' })).statusCode).toBe(404);
    expect((await review(SCAN_A, { action: 'confirm', extra: 1 })).statusCode).toBe(400);
  });
});

describe('GET /v1/scans/:id/experimental', () => {
  const get = async (id: string, role = 'nurse_operator', site = SITE_A) =>
    app.inject({ method: 'GET', url: `/v1/scans/${id}/experimental`, headers: bearer(await tokenFor(role, site)) });
  const feature = (domain: string, name: string, value: number, ts: string, pv = 'v1') =>
    pool.query(
      `INSERT INTO features(scan_id,domain,name,value,pipeline_version,feature_availability_timestamp) VALUES ($1,$2,$3,$4,$5,$6)`,
      [SCAN_A, domain, name, value, pv, ts],
    );
  const setFlag = (enabled: boolean) =>
    pool.query(
      `INSERT INTO site_protocol_flags(site_id,flag,enabled,changed_by) VALUES ($1,'show_experimental_at_bedside',$2,'t')`,
      [SITE_A, enabled],
    );
  const viewAudits = async () =>
    (await pool.query(`SELECT count(*)::int AS n FROM clinical_audit_log WHERE event_type='view_experimental'`)).rows[0].n;

  beforeEach(async () => {
    await pool.query('DELETE FROM features WHERE scan_id=$1', [SCAN_A]);
    await pool.query('DELETE FROM site_protocol_flags WHERE site_id=$1', [SITE_A]);
  });

  it('disabled by default returns enabled:false and writes no audit', async () => {
    await feature('rppg_face', 'heart_rate', 80, '2026-10-01T00:00:00Z');
    const before = await viewAudits();
    const r = await get(SCAN_A);
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ enabled: false, items: [] });
    await setFlag(false);
    expect((await get(SCAN_A, 'clinician')).json()).toEqual({ enabled: false, items: [] });
    expect(await viewAudits()).toBe(before);
  });

  it('enabled flag returns rounded integer bpm (latest per domain) and audits every call', async () => {
    await setFlag(true);
    await feature('rppg_face', 'heart_rate', 70.2, '2026-10-01T00:00:00Z');
    await feature('rppg_face', 'heart_rate', 81.6, '2026-10-01T01:00:00Z', 'v2');
    await feature('rppg_fingertip', 'heart_rate', 64.4, '2026-10-01T00:00:00Z');
    const before = await viewAudits();
    const r = await get(SCAN_A);
    expect(r.statusCode).toBe(200);
    const notice = 'Not validated — do not use for care decisions. Use the monitor value.';
    expect(r.json()).toEqual({
      enabled: true,
      items: [
        { domain: 'rppg_face', pulse_rate_bpm: 82, label: 'EXPERIMENTAL', notice },
        { domain: 'rppg_fingertip', pulse_rate_bpm: 64, label: 'EXPERIMENTAL', notice },
      ],
    });
    await get(SCAN_A, 'clinician');
    expect(await viewAudits()).toBe(before + 2);
  });

  it('never returns colour/hrv or other domains/names', async () => {
    await setFlag(true);
    await feature('facial', 'heart_rate', 90, '2026-10-01T00:00:00Z');
    await feature('ocular', 'colour_index', 12, '2026-10-01T00:00:00Z');
    await feature('rppg_face', 'hrv_rmssd', 33, '2026-10-01T00:00:00Z');
    await feature('rppg_fingertip', 'colour_mean', 5, '2026-10-01T00:00:00Z');
    expect((await get(SCAN_A)).json()).toEqual({ enabled: true, items: [] });
  });

  it('other-site scan gives 404, researcher gives 403', async () => {
    expect((await get(SCAN_OTHER)).statusCode).toBe(404);
    expect((await get(SCAN_A, 'researcher')).statusCode).toBe(403);
  });
});
