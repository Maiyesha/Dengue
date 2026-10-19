import { randomUUID, createHash } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { getTestPool } from '../pg';
import { seedFixtures, clearFixtures, SITE_A, SITE_B, PATIENT_A, CONSENT_VERSION } from '../fixtures';
import { buildTestApp, tokenFor, deviceTokenFor, bearer, WRAPPED, type TestApp } from './helpers';

const pool = getTestPool();
let ta: TestApp;
let app: FastifyInstance;
const scanIds: string[] = [];

const sha = (s: string) => createHash('sha256').update(s).digest('hex');

async function mkScan(
  status = 'capture_pending',
  attempts: Array<[string, number] | [string, number, string]> = [['neutral_face', 1], ['fingertip_ppg', 1]],
  patient = PATIENT_A,
  metadata: Record<string, unknown> = {},
) {
  const id = randomUUID();
  scanIds.push(id);
  await pool.query(
    `INSERT INTO scans(id,client_session_id,patient_id,site_id,captured_at,protocol_version,status,metadata)
     VALUES ($1,gen_random_uuid(),$2,$3,now() - interval '40 days','p1',$4::scan_status,$5::jsonb)`,
    [id, patient, SITE_A, status, JSON.stringify({ capture_steps: ['neutral_face', 'fingertip_ppg', 'ocular_capture'], ...metadata })],
  );
  for (const [step, attempt, verdict] of attempts) {
    await pool.query(
      `INSERT INTO scan_step_attempts(scan_id,step,attempt,device_verdict) VALUES ($1,$2,$3,$4)`,
      [id, step, attempt, verdict ?? 'ACCEPT'],
    );
  }
  return id;
}

const post = async (url: string, body?: unknown, o: { token?: string; key?: string } = {}) =>
  app.inject({
    method: 'POST',
    url,
    headers: {
      ...bearer(o.token ?? (await tokenFor('nurse_operator', SITE_A))),
      'idempotency-key': o.key ?? randomUUID(),
    },
    payload: (body ?? {}) as object,
  });

const declare = (scan: string, step: string, kind: string, content: string, attempt = 1, token?: string) =>
  post(`/v1/scans/${scan}/artefacts`, { step, attempt, kind, size_bytes: 10, sha256: sha(content), ...WRAPPED }, { token });

const keyOf = (scan: string, step: string, kind: string, attempt = 1) =>
  `captures/${SITE_A}/${scan}/${step}/${attempt}/${kind}`;

/** Declares, stores the (matching) object, and completes. */
async function upload(scan: string, step: string, kind: string, attempt = 1) {
  const d = await declare(scan, step, kind, `${scan}-${step}-${kind}-${attempt}`, attempt);
  expect(d.statusCode).toBeLessThan(300);
  ta.fakes.objectStore.put(keyOf(scan, step, kind, attempt), sha(`${scan}-${step}-${kind}-${attempt}`));
  return post(`/v1/artefacts/${d.json().artefact_id}/complete`);
}

const statusOf = async (scan: string) =>
  (await pool.query('SELECT status::text AS s FROM scans WHERE id = $1', [scan])).rows[0].s;

// Consent-gate patient (site A): tests append consent rows (latest recorded_at wins).
const P_GATE = '00000000-0000-4000-a000-0000000006a1';
const OLD_VERSION = 'art-v0';
const consent = (patient: string, o: { version?: string; withdrawn?: boolean } = {}) =>
  pool.query(
    `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at,withdrawn_at)
     VALUES ($1,$2,true,now(),${o.withdrawn ? 'now()' : 'NULL'})`,
    [patient, o.version ?? CONSENT_VERSION],
  );
const postHoc = async (scan: string) =>
  (await pool.query(
    `SELECT event_type, actor_role, patient_pseudonym, resource_type, outcome FROM clinical_audit_log
      WHERE event_type = 'capture_rejected_post_hoc' AND resource_id = $1 ORDER BY id`,
    [scan],
  )).rows;

beforeAll(async () => {
  await seedFixtures(pool);
  await pool.query(
    `INSERT INTO patients(id,participant_code,pseudonym_id,site_id,cohort) VALUES ($1,'DS-RLSA-00601','ps-art-gate',$2,'dengue')
     ON CONFLICT DO NOTHING`,
    [P_GATE, SITE_A],
  );
  await pool.query(`INSERT INTO consent_versions(version,is_current) VALUES ($1,false) ON CONFLICT DO NOTHING`, [OLD_VERSION]);
  ta = await buildTestApp();
  app = ta.app;
});

afterAll(async () => {
  await pool.query('DELETE FROM artefacts WHERE scan_id = ANY($1)', [scanIds]);
  await pool.query('DELETE FROM scan_step_attempts WHERE scan_id = ANY($1)', [scanIds]);
  await pool.query('DELETE FROM scans WHERE id = ANY($1)', [scanIds]);
  await pool.query('DELETE FROM consents WHERE patient_id = $1', [P_GATE]);
  await pool.query('DELETE FROM patients WHERE id = $1', [P_GATE]);
  await pool.query('DELETE FROM consent_versions WHERE version = $1', [OLD_VERSION]);
  await clearFixtures(pool);
  await app.close();
});

describe('artefact uploads', () => {
  it('declare returns upload id', async () => {
    const scan = await mkScan();
    const r = await declare(scan, 'neutral_face', 'video', 'a');
    expect(r.statusCode).toBe(201);
    const body = r.json();
    expect(body.upload_id).toMatch(/^upload-/);
    const row = (await pool.query('SELECT object_key, status FROM artefacts WHERE id = $1', [body.artefact_id])).rows[0];
    expect(row.object_key).toBe(keyOf(scan, 'neutral_face', 'video'));
    expect(row.object_key).not.toMatch(/DS-/);
    expect(row.status).toBe('declared');
  });

  it('duplicate declare returns the existing artefact; different sha -> 409 DS_UPLOAD_003', async () => {
    const scan = await mkScan();
    const a = await declare(scan, 'neutral_face', 'video', 'a');
    const b = await declare(scan, 'neutral_face', 'video', 'a');
    expect(b.json()).toEqual(a.json());
    const c = await declare(scan, 'neutral_face', 'video', 'different');
    expect(c.statusCode).toBe(409);
    expect(c.json().error.code).toBe('DS_UPLOAD_003');
  });

  it('declare for a step that is not part of the capture -> 422 DS_UPLOAD_002', async () => {
    const scan = await mkScan();
    const r = await declare(scan, 'dorsal_tongue', 'video', 'a');
    expect(r.statusCode).toBe(422);
    expect(r.json().error.code).toBe('DS_UPLOAD_002');
  });

  it('part url: ttl 900; part number 0 -> 400; 10001 -> 400', async () => {
    const scan = await mkScan();
    const id = (await declare(scan, 'neutral_face', 'video', 'a')).json().artefact_id;
    const ok = await post(`/v1/artefacts/${id}/parts/1/url`);
    expect(ok.statusCode).toBe(200);
    expect(ok.json().expires_in).toBe(900);
    expect(ok.json().url).toContain('partNumber=1');
    expect((await post(`/v1/artefacts/${id}/parts/0/url`)).statusCode).toBe(400);
    expect((await post(`/v1/artefacts/${id}/parts/10001/url`)).statusCode).toBe(400);
    expect((await post(`/v1/artefacts/${id}/parts/10000/url`)).statusCode).toBe(200);
  });

  it('part url is not idempotency-stored: the same key returns a fresh URL each call', async () => {
    const scan = await mkScan();
    const id = (await declare(scan, 'neutral_face', 'video', 'a')).json().artefact_id;
    const key = randomUUID();
    const a = await post(`/v1/artefacts/${id}/parts/1/url`, {}, { key });
    const b = await post(`/v1/artefacts/${id}/parts/1/url`, {}, { key });
    expect(a.statusCode).toBe(200);
    expect(b.statusCode).toBe(200);
    expect(b.headers['idempotent-replayed']).toBeUndefined();
    expect(b.json().url).not.toBe(a.json().url);
    const stored = await pool.query(`SELECT 1 FROM idempotency_keys WHERE key = $1`, [key]);
    expect(stored.rowCount).toBe(0);
    // No Idempotency-Key at all is fine too.
    const c = await app.inject({
      method: 'POST',
      url: `/v1/artefacts/${id}/parts/2/url`,
      headers: bearer(await tokenFor('nurse_operator', SITE_A)),
      payload: {},
    });
    expect(c.statusCode).toBe(200);
  });

  it('complete with matching sha -> received_verified', async () => {
    const scan = await mkScan();
    const r = await upload(scan, 'neutral_face', 'video');
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ status: 'received_verified' });
    const s = (await pool.query('SELECT status FROM artefacts WHERE scan_id = $1', [scan])).rows[0].status;
    expect(s).toBe('received_verified');
    expect(await statusOf(scan)).toBe('capture_pending');
  });

  it('mismatch -> 422 DS_UPLOAD_001, artefact rejected, never received_verified, no quality trigger', async () => {
    const scan = await mkScan();
    const d = await declare(scan, 'neutral_face', 'video', 'good');
    ta.fakes.objectStore.put(keyOf(scan, 'neutral_face', 'video'), sha('corrupted'));
    const r = await post(`/v1/artefacts/${d.json().artefact_id}/complete`);
    expect(r.statusCode).toBe(422);
    expect(r.json().error.code).toBe('DS_UPLOAD_001');
    const s = (await pool.query('SELECT status FROM artefacts WHERE id = $1', [d.json().artefact_id])).rows[0].status;
    expect(s).toBe('rejected');
    // A retry still cannot verify it.
    const again = await post(`/v1/artefacts/${d.json().artefact_id}/complete`);
    expect(again.statusCode).toBe(422);
    expect(await statusOf(scan)).toBe('capture_pending');
  });

  it('enqueue after the last core artefact; a re-complete enqueues again (at least once)', async () => {
    const scan = await mkScan();
    const q = ta.fakes.qualityQueue.enqueued;
    const count = () => q.filter((x) => x === scan).length;
    await upload(scan, 'neutral_face', 'video');
    await upload(scan, 'neutral_face', 'roi_trace');
    await upload(scan, 'neutral_face', 'metadata');
    await upload(scan, 'fingertip_ppg', 'video');
    expect(count()).toBe(0);
    expect(await statusOf(scan)).toBe('capture_pending');
    const last = await upload(scan, 'fingertip_ppg', 'roi_trace');
    expect(last.statusCode).toBe(200);
    expect(count()).toBe(1);
    expect(await statusOf(scan)).toBe('quality_pending');
    // Re-completing (a client retry) enqueues again: delivery is at-least-once, the quality worker
    // dedupes by scan_id.
    const id = (await pool.query(`SELECT id FROM artefacts WHERE scan_id = $1 AND kind = 'roi_trace' AND step = 'fingertip_ppg'`, [scan])).rows[0].id;
    expect((await post(`/v1/artefacts/${id}/complete`)).statusCode).toBe(200);
    expect(count()).toBe(2);
  });

  it('enqueue failure after commit: the retry with the same key enqueues (F6)', async () => {
    const scan = await mkScan();
    await upload(scan, 'neutral_face', 'video');
    await upload(scan, 'neutral_face', 'roi_trace');
    await upload(scan, 'fingertip_ppg', 'video');
    const d = await declare(scan, 'fingertip_ppg', 'roi_trace', 'last');
    ta.fakes.objectStore.put(keyOf(scan, 'fingertip_ppg', 'roi_trace'), sha('last'));
    ta.fakes.qualityQueue.fail = 1;
    const key = randomUUID();
    const first = await post(`/v1/artefacts/${d.json().artefact_id}/complete`, {}, { key });
    expect(first.statusCode).toBe(500);
    expect(await statusOf(scan)).toBe('quality_pending'); // committed before the enqueue
    expect(ta.fakes.qualityQueue.enqueued.filter((x) => x === scan)).toHaveLength(0);
    const retry = await post(`/v1/artefacts/${d.json().artefact_id}/complete`, {}, { key });
    expect(retry.statusCode).toBe(200);
    expect(ta.fakes.qualityQueue.enqueued.filter((x) => x === scan)).toHaveLength(1);
  });

  it('S3 completed but the DB rolled back: the complete retry succeeds (F5)', async () => {
    const scan = await mkScan();
    const d = await declare(scan, 'neutral_face', 'video', 'body');
    ta.fakes.objectStore.put(keyOf(scan, 'neutral_face', 'video'), sha('body'));
    ta.fakes.objectStore.failSha256 = 1; // fails after CompleteMultipartUpload succeeded
    const key = randomUUID();
    const first = await post(`/v1/artefacts/${d.json().artefact_id}/complete`, {}, { key });
    expect(first.statusCode).toBe(500);
    const row = async () => (await pool.query('SELECT status FROM artefacts WHERE id = $1', [d.json().artefact_id])).rows[0].status;
    expect(await row()).toBe('declared');
    const retry = await post(`/v1/artefacts/${d.json().artefact_id}/complete`, {}, { key });
    expect(retry.statusCode).toBe(200);
    expect(await row()).toBe('received_verified');
  });

  it('short upload -> 409 DS_UPLOAD_005 (status unchanged); completes once the remaining parts arrive', async () => {
    const scan = await mkScan();
    const d = await declare(scan, 'neutral_face', 'video', 'parts'); // size_bytes 10
    const id = d.json().artefact_id;
    const k = keyOf(scan, 'neutral_face', 'video');
    expect((await post(`/v1/artefacts/${id}/parts/1/url`)).statusCode).toBe(200);
    ta.fakes.objectStore.put(k, sha('parts'), { full: false });
    ta.fakes.objectStore.uploadPart(k, 1, 4);
    const key = randomUUID();
    const short = await post(`/v1/artefacts/${id}/complete`, {}, { key });
    expect(short.statusCode).toBe(409);
    expect(short.json().error.code).toBe('DS_UPLOAD_005');
    expect(short.json().error.detail).toEqual({ received_bytes: 4, size_bytes: 10 });
    expect((await pool.query('SELECT status FROM artefacts WHERE id = $1', [id])).rows[0].status).toBe('uploading');
    ta.fakes.objectStore.uploadPart(k, 2, 6);
    const done = await post(`/v1/artefacts/${id}/complete`, {}, { key }); // same key: not a stored replay
    expect(done.statusCode).toBe(200);
    expect(done.json()).toEqual({ status: 'received_verified' });
  });

  it('rejected artefact: re-declare with the same sha opens a new upload and can then be verified', async () => {
    const scan = await mkScan();
    const k = keyOf(scan, 'neutral_face', 'video');
    const d = await declare(scan, 'neutral_face', 'video', 'good');
    ta.fakes.objectStore.put(k, sha('corrupted'));
    expect((await post(`/v1/artefacts/${d.json().artefact_id}/complete`)).statusCode).toBe(422);
    const again = await declare(scan, 'neutral_face', 'video', 'good');
    expect(again.statusCode).toBe(200);
    expect(again.json().artefact_id).toBe(d.json().artefact_id);
    expect(again.json().upload_id).not.toBe(d.json().upload_id);
    const row = (await pool.query('SELECT status, upload_id FROM artefacts WHERE id = $1', [d.json().artefact_id])).rows[0];
    expect(row).toEqual({ status: 'declared', upload_id: again.json().upload_id });
    ta.fakes.objectStore.put(k, sha('good'));
    const ok = await post(`/v1/artefacts/${d.json().artefact_id}/complete`);
    expect(ok.statusCode).toBe(200);
    // A different sha on a rejected artefact is still DS_UPLOAD_003.
    expect((await declare(scan, 'neutral_face', 'video', 'other')).json().error.code).toBe('DS_UPLOAD_003');
  });

  it('part url for a verified or rejected artefact -> 409 DS_UPLOAD_004', async () => {
    const scan = await mkScan();
    const v = await upload(scan, 'neutral_face', 'video');
    expect(v.statusCode).toBe(200);
    const vid = (await pool.query(`SELECT id FROM artefacts WHERE scan_id = $1 AND kind = 'video'`, [scan])).rows[0].id;
    const r = await post(`/v1/artefacts/${vid}/parts/1/url`);
    expect(r.statusCode).toBe(409);
    expect(r.json().error.code).toBe('DS_UPLOAD_004');
    const d = await declare(scan, 'neutral_face', 'roi_trace', 'x');
    ta.fakes.objectStore.put(keyOf(scan, 'neutral_face', 'roi_trace'), sha('y'));
    expect((await post(`/v1/artefacts/${d.json().artefact_id}/complete`)).statusCode).toBe(422);
    expect((await post(`/v1/artefacts/${d.json().artefact_id}/parts/1/url`)).json().error.code).toBe('DS_UPLOAD_004');
  });

  it('declare on a scan that no longer accepts artefacts -> 409 DS_STATE_001', async () => {
    for (const st of ['quality_pending', 'quality_failed']) {
      const scan = await mkScan(st);
      const r = await declare(scan, 'neutral_face', 'video', 'a');
      expect(r.statusCode).toBe(409);
      expect(r.json().error.code).toBe('DS_STATE_001');
    }
  });

  it('two concurrent final completes: at least one enqueue, scan quality_pending', async () => {
    const scan = await mkScan();
    await upload(scan, 'neutral_face', 'video');
    await upload(scan, 'neutral_face', 'roi_trace');
    // Declare both remaining artefacts, then complete them concurrently (and the same one twice).
    const ids: string[] = [];
    for (const kind of ['video', 'roi_trace']) {
      const d = await declare(scan, 'fingertip_ppg', kind, `${scan}-fingertip_ppg-${kind}-1`);
      ta.fakes.objectStore.put(keyOf(scan, 'fingertip_ppg', kind), sha(`${scan}-fingertip_ppg-${kind}-1`));
      ids.push(d.json().artefact_id);
    }
    const rs = await Promise.all([ids[0], ids[1], ids[1], ids[0]].map((id) => post(`/v1/artefacts/${id}/complete`)));
    expect(rs.map((x) => x.statusCode)).toEqual([200, 200, 200, 200]);
    // Exactly one request performs the transition; requests serialised after it may enqueue again
    // (at-least-once, F6). The worker dedupes.
    expect(ta.fakes.qualityQueue.enqueued.filter((x) => x === scan).length).toBeGreaterThanOrEqual(1);
    expect(await statusOf(scan)).toBe('quality_pending');
  });

  it('face artefacts verified but fingertip not -> stays capture_pending, no enqueue', async () => {
    const scan = await mkScan();
    await upload(scan, 'neutral_face', 'video');
    await upload(scan, 'neutral_face', 'roi_trace');
    expect(await statusOf(scan)).toBe('capture_pending');
    expect(ta.fakes.qualityQueue.enqueued.filter((x) => x === scan)).toHaveLength(0);
  });

  it('only the latest attempt counts toward the quality trigger', async () => {
    const scan = await mkScan('capture_pending', [['neutral_face', 1], ['neutral_face', 2], ['fingertip_ppg', 1]]);
    await upload(scan, 'neutral_face', 'video', 1);
    await upload(scan, 'neutral_face', 'roi_trace', 1);
    await upload(scan, 'fingertip_ppg', 'video');
    await upload(scan, 'fingertip_ppg', 'roi_trace');
    expect(await statusOf(scan)).toBe('capture_pending'); // attempt 2 of neutral_face is the latest
    await upload(scan, 'neutral_face', 'video', 2);
    await upload(scan, 'neutral_face', 'roi_trace', 2);
    expect(await statusOf(scan)).toBe('quality_pending');
    expect(ta.fakes.qualityQueue.enqueued.filter((x) => x === scan)).toHaveLength(1);
  });

  it('device token works on its own site; from another site -> 404', async () => {
    const scan = await mkScan();
    const own = await deviceTokenFor(randomUUID(), SITE_A);
    const other = await deviceTokenFor(randomUUID(), SITE_B);
    const d = await declare(scan, 'neutral_face', 'video', 'dev', 1, own);
    expect(d.statusCode).toBe(201);
    const id = d.json().artefact_id;
    expect((await declare(scan, 'neutral_face', 'roi_trace', 'x', 1, other)).statusCode).toBe(404);
    expect((await post(`/v1/artefacts/${id}/parts/1/url`, {}, { token: other })).statusCode).toBe(404);
    expect((await post(`/v1/artefacts/${id}/complete`, {}, { token: other })).statusCode).toBe(404);
    expect((await post(`/v1/artefacts/${id}/parts/1/url`, {}, { token: own })).statusCode).toBe(200);
    // Other-site nurse is also 404, researcher 403.
    const nurseB = await tokenFor('nurse_operator', SITE_B);
    expect((await declare(scan, 'neutral_face', 'roi_trace', 'x', 1, nurseB)).statusCode).toBe(404);
    expect((await declare(scan, 'neutral_face', 'roi_trace', 'x', 1, await tokenFor('researcher'))).statusCode).toBe(403);
    const ev = (await pool.query(
      `SELECT patient_pseudonym FROM clinical_audit_log WHERE event_type = 'device_event' AND resource_id = $1`,
      [id],
    )).rows;
    // The device cannot read patients; the pseudonym comes from scan_consent_rejection().
    expect(ev).toEqual([{ patient_pseudonym: 'ps-rls-a' }]);
  });

  it('rejects unknown fields and bad sha256 -> 400', async () => {
    const scan = await mkScan();
    const base = { step: 'neutral_face', attempt: 1, kind: 'video', size_bytes: 10, sha256: sha('a'), ...WRAPPED };
    expect((await post(`/v1/scans/${scan}/artefacts`, { ...base, extra: 1 })).statusCode).toBe(400);
    expect((await post(`/v1/scans/${scan}/artefacts`, { ...base, sha256: 'abc' })).statusCode).toBe(400);
  });

  it('C1: declare requires and stores wrapped_key, key_alg (RSA-OAEP-256 only) and kms_key_id', async () => {
    const scan = await mkScan();
    const base = { step: 'neutral_face', attempt: 1, kind: 'video', size_bytes: 10, sha256: sha('w'), ...WRAPPED };
    for (const k of ['wrapped_key', 'key_alg', 'kms_key_id'] as const) {
      const { [k]: _omit, ...rest } = base;
      const r = await post(`/v1/scans/${scan}/artefacts`, rest);
      expect(r.statusCode).toBe(400);
      expect(r.json().error.code).toBe('DS_VALIDATION_001');
    }
    for (const bad of [{ key_alg: 'RSA-OAEP' }, { wrapped_key: 'not base64!' }, { wrapped_key: Buffer.alloc(256, 1).toString('base64') },
      { kms_key_id: '' }]) {
      expect((await post(`/v1/scans/${scan}/artefacts`, { ...base, ...bad })).statusCode).toBe(400);
    }
    const ok = await post(`/v1/scans/${scan}/artefacts`, base);
    expect(ok.statusCode).toBe(201);
    const row = (await pool.query('SELECT wrapped_key, key_alg, kms_key_id FROM artefacts WHERE id = $1', [ok.json().artefact_id])).rows[0];
    expect(row).toEqual({ wrapped_key: WRAPPED.wrapped_key, key_alg: 'RSA-OAEP-256', kms_key_id: 'kms-test-key' });
  });

  it('C1: the database refuses another key_alg or a missing wrapped key', async () => {
    const scan = await mkScan();
    const ins = (alg: string | null, wk: string | null) => pool.query(
      `INSERT INTO artefacts(scan_id,step,attempt,kind,sha256,object_key,wrapped_key,key_alg,kms_key_id)
       VALUES ($1,'neutral_face',1,'video',$2,$3,$4,$5,'k')`, [scan, sha('db'), `k-${randomUUID()}`, wk, alg]);
    await expect(ins('RSA-OAEP', 'x')).rejects.toThrow();
    await expect(ins('RSA-OAEP-256', null)).rejects.toThrow();
  });
});

describe('device_id and consent re-check (F1, F2)', () => {
  const scanDevice = async (scan: string) =>
    (await pool.query('SELECT device_id FROM scans WHERE id = $1', [scan])).rows[0].device_id;

  it('the first device declare sets scans.device_id; a later device does not overwrite it', async () => {
    const scan = await mkScan();
    const d1 = randomUUID();
    const d2 = randomUUID();
    expect((await declare(scan, 'neutral_face', 'video', 'v', 1, await deviceTokenFor(d1, SITE_A))).statusCode).toBe(201);
    expect(await scanDevice(scan)).toBe(d1);
    expect((await declare(scan, 'neutral_face', 'roi_trace', 'r', 1, await deviceTokenFor(d2, SITE_A))).statusCode).toBe(201);
    expect(await scanDevice(scan)).toBe(d1);
  });

  it('a user declare does not set device_id', async () => {
    const scan = await mkScan();
    expect((await declare(scan, 'neutral_face', 'video', 'v')).statusCode).toBe(201);
    expect(await scanDevice(scan)).toBeNull();
  });

  it('declare after withdrawal -> 451 DS_REG_001 with a committed post-hoc audit row (device pseudonym)', async () => {
    await consent(P_GATE);
    const scan = await mkScan('capture_pending', undefined, P_GATE);
    await consent(P_GATE, { withdrawn: true });
    const r = await declare(scan, 'neutral_face', 'video', 'v', 1, await deviceTokenFor(randomUUID(), SITE_A));
    expect(r.statusCode).toBe(451);
    expect(r.json().error.code).toBe('DS_REG_001');
    expect((await pool.query('SELECT 1 FROM artefacts WHERE scan_id = $1', [scan])).rowCount).toBe(0);
    expect(await scanDevice(scan)).toBeNull();
    expect(await postHoc(scan)).toEqual([
      { event_type: 'capture_rejected_post_hoc', actor_role: 'device', patient_pseudonym: 'ps-art-gate', resource_type: 'scan', outcome: 'DS_REG_001' },
    ]);
  });

  it('complete after re-consent to a superseded version -> 451 DS_REG_002, artefact not verified', async () => {
    await consent(P_GATE);
    const scan = await mkScan('capture_pending', undefined, P_GATE);
    const d = await declare(scan, 'neutral_face', 'video', 'v');
    expect(d.statusCode).toBe(201);
    ta.fakes.objectStore.put(keyOf(scan, 'neutral_face', 'video'), sha('v'));
    await consent(P_GATE, { version: OLD_VERSION });
    const r = await post(`/v1/artefacts/${d.json().artefact_id}/complete`);
    expect(r.statusCode).toBe(451);
    expect(r.json().error.code).toBe('DS_REG_002');
    expect((await pool.query('SELECT status FROM artefacts WHERE id = $1', [d.json().artefact_id])).rows[0].status).toBe('declared');
    expect(await postHoc(scan)).toEqual([
      { event_type: 'capture_rejected_post_hoc', actor_role: 'nurse_operator', patient_pseudonym: 'ps-art-gate', resource_type: 'scan', outcome: 'DS_REG_002' },
    ]);
  });
});

describe('scan lifecycle (F9)', () => {
  const attempts = async (scan: string) =>
    (await pool.query(
      `SELECT step::text, attempt, device_verdict FROM scan_step_attempts WHERE scan_id = $1 ORDER BY step, attempt`,
      [scan],
    )).rows;
  const enqueued = (scan: string) => ta.fakes.qualityQueue.enqueued.filter((x) => x === scan).length;

  it('(a) POST /v1/scans pre-registration (no attempts): device declare creates the attempt, upload completes', async () => {
    const created = await post('/v1/scans', {
      client_session_id: randomUUID(),
      patient_id: PATIENT_A,
      captured_at: '2025-01-01T08:00:00Z',
      offline: false,
      protocol_version: 'p1',
      capture_steps: ['neutral_face', 'fingertip_ppg'],
      device_attempts: [],
      metadata: {
        camera_model: 'iPhone15,3', frame_rate: 60, resolution: '1920x1080', exposure: 0.5, distance_cm: 40,
        angle_deg: 0, lighting_lux: 500, ambient_temp_c: 27, ambient_humidity_pct: 70, mount: 'holder',
        lighting_type: 'led_ring', exposure_duration_ms: 8,
      },
    });
    expect(created.statusCode).toBe(201);
    const scan = created.json().scan.id as string;
    scanIds.push(scan);
    const dev = await deviceTokenFor(randomUUID(), SITE_A);
    for (const step of ['neutral_face', 'fingertip_ppg']) {
      for (const kind of ['video', 'roi_trace']) {
        const d = await declare(scan, step, kind, `${step}-${kind}`, 1, dev);
        expect(d.statusCode, `${step} ${kind}`).toBe(201);
        ta.fakes.objectStore.put(keyOf(scan, step, kind), sha(`${step}-${kind}`));
        expect((await post(`/v1/artefacts/${d.json().artefact_id}/complete`, {}, { token: dev })).statusCode).toBe(200);
      }
    }
    expect(await attempts(scan)).toEqual([
      { step: 'fingertip_ppg', attempt: 1, device_verdict: 'ACCEPT' },
      { step: 'neutral_face', attempt: 1, device_verdict: 'ACCEPT' },
    ]);
    expect(await statusOf(scan)).toBe('quality_pending');
    expect(enqueued(scan)).toBe(1);
  });

  it('(a) declare takes an optional device_verdict for a new attempt; attempt must be 1..3', async () => {
    const scan = await mkScan('capture_pending', []);
    const body = (o: Record<string, unknown>) => ({ step: 'fingertip_ppg', attempt: 1, kind: 'video', size_bytes: 10, sha256: sha('u'), ...WRAPPED, ...o });
    const r = await post(`/v1/scans/${scan}/artefacts`, body({ device_verdict: 'UNABLE_TO_ACQUIRE' }));
    expect(r.statusCode).toBe(201);
    expect(await attempts(scan)).toEqual([{ step: 'fingertip_ppg', attempt: 1, device_verdict: 'UNABLE_TO_ACQUIRE' }]);
    // An existing attempt keeps its verdict.
    const again = await post(`/v1/scans/${scan}/artefacts`, body({ kind: 'roi_trace', device_verdict: 'RECAPTURE' }));
    expect(again.statusCode).toBe(201);
    expect((await attempts(scan))[0].device_verdict).toBe('UNABLE_TO_ACQUIRE');
    for (const bad of [body({ attempt: 0 }), body({ attempt: 4 }), body({ device_verdict: 'MAYBE' })]) {
      expect((await post(`/v1/scans/${scan}/artefacts`, bad)).statusCode).toBe(400);
    }
  });

  it('(b) a core step whose latest attempt is UNABLE_TO_ACQUIRE is settled: the other core step triggers quality', async () => {
    const scan = await mkScan('capture_pending', [['neutral_face', 1], ['fingertip_ppg', 1, 'UNABLE_TO_ACQUIRE']]);
    await upload(scan, 'neutral_face', 'video');
    expect(await statusOf(scan)).toBe('capture_pending');
    await upload(scan, 'neutral_face', 'roi_trace');
    expect(await statusOf(scan)).toBe('quality_pending');
    expect(enqueued(scan)).toBe(1);
  });

  it('(b) a core step listed in metadata.unable_to_acquire is settled', async () => {
    const scan = await mkScan('capture_pending', [['neutral_face', 1], ['fingertip_ppg', 1]], PATIENT_A, {
      unable_to_acquire: ['neutral_face'],
    });
    await upload(scan, 'fingertip_ppg', 'video');
    await upload(scan, 'fingertip_ppg', 'roi_trace');
    expect(await statusOf(scan)).toBe('quality_pending');
  });

  it('(b) no verified core step -> no trigger even when every core step is settled', async () => {
    const scan = await mkScan('capture_pending', [
      ['neutral_face', 1, 'UNABLE_TO_ACQUIRE'], ['fingertip_ppg', 1, 'UNABLE_TO_ACQUIRE'], ['ocular_capture', 1],
    ]);
    await upload(scan, 'ocular_capture', 'video');
    await upload(scan, 'ocular_capture', 'roi_trace');
    expect(await statusOf(scan)).toBe('capture_pending');
    expect(enqueued(scan)).toBe(0);
  });

  it('(b) a settled step that was later recaptured (latest attempt ACCEPT) is not settled', async () => {
    const scan = await mkScan('capture_pending', [
      ['neutral_face', 1], ['fingertip_ppg', 1, 'UNABLE_TO_ACQUIRE'], ['fingertip_ppg', 2],
    ]);
    await upload(scan, 'neutral_face', 'video');
    await upload(scan, 'neutral_face', 'roi_trace');
    expect(await statusOf(scan)).toBe('capture_pending');
    await upload(scan, 'fingertip_ppg', 'video', 2);
    await upload(scan, 'fingertip_ppg', 'roi_trace', 2);
    expect(await statusOf(scan)).toBe('quality_pending');
  });

  it('(c) acquisition_failure: declare and complete for existing attempts, no enqueue; new attempts refused', async () => {
    const scan = await mkScan('acquisition_failure');
    const r = await upload(scan, 'neutral_face', 'video');
    expect(r.statusCode).toBe(200);
    await upload(scan, 'neutral_face', 'roi_trace');
    await upload(scan, 'fingertip_ppg', 'video');
    await upload(scan, 'fingertip_ppg', 'roi_trace');
    expect(await statusOf(scan)).toBe('acquisition_failure');
    expect(enqueued(scan)).toBe(0);
    const fresh = await declare(scan, 'neutral_face', 'video', 'n', 2);
    expect(fresh.statusCode).toBe(409);
    expect(fresh.json().error.code).toBe('DS_STATE_001');
  });
});

describe('POST /v1/scans/:id/features/extract', () => {
  it('before quality_passed -> 422 DS_QG_000', async () => {
    const scan = await mkScan('quality_pending');
    const sys = await tokenFor('system_agent');
    const r = await post(`/v1/scans/${scan}/features/extract`, {}, { token: sys });
    expect(r.statusCode).toBe(422);
    expect(r.json().error.code).toBe('DS_QG_000');
  });

  it('at quality_passed -> 202; site roles and devices -> 403', async () => {
    const scan = await mkScan('quality_passed');
    const sys = await tokenFor('system_agent');
    expect((await post(`/v1/scans/${scan}/features/extract`, {}, { token: sys })).statusCode).toBe(202);
    const au = (await pool.query(
      `SELECT event_type, outcome FROM clinical_audit_log WHERE resource_id = $1 AND outcome = 'features:extract_requested'`,
      [scan],
    )).rows;
    expect(au).toEqual([{ event_type: 'data_access', outcome: 'features:extract_requested' }]);
    expect((await post(`/v1/scans/${scan}/features/extract`, {})).statusCode).toBe(403);
    expect((await post(`/v1/scans/${scan}/features/extract`, {}, { token: await deviceTokenFor(randomUUID(), SITE_A) })).statusCode).toBe(403);
  });
});
