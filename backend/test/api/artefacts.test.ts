import { randomUUID, createHash } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { getTestPool } from '../pg';
import { seedFixtures, clearFixtures, SITE_A, SITE_B, PATIENT_A } from '../fixtures';
import { buildTestApp, tokenFor, deviceTokenFor, bearer, type TestApp } from './helpers';

const pool = getTestPool();
let ta: TestApp;
let app: FastifyInstance;
const scanIds: string[] = [];

const sha = (s: string) => createHash('sha256').update(s).digest('hex');

async function mkScan(status = 'capture_pending', attempts: Array<[string, number]> = [['neutral_face', 1], ['fingertip_ppg', 1]]) {
  const id = randomUUID();
  scanIds.push(id);
  await pool.query(
    `INSERT INTO scans(id,client_session_id,patient_id,site_id,captured_at,protocol_version,status,metadata)
     VALUES ($1,gen_random_uuid(),$2,$3,now() - interval '40 days','p1',$4::scan_status,
             '{"capture_steps":["neutral_face","fingertip_ppg"]}'::jsonb)`,
    [id, PATIENT_A, SITE_A, status],
  );
  for (const [step, attempt] of attempts) {
    await pool.query(
      `INSERT INTO scan_step_attempts(scan_id,step,attempt,device_verdict) VALUES ($1,$2,$3,'ACCEPT')`,
      [id, step, attempt],
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
  post(`/v1/scans/${scan}/artefacts`, { step, attempt, kind, size_bytes: 10, sha256: sha(content) }, { token });

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

beforeAll(async () => {
  await seedFixtures(pool);
  ta = await buildTestApp();
  app = ta.app;
});

afterAll(async () => {
  await pool.query('DELETE FROM artefacts WHERE scan_id = ANY($1)', [scanIds]);
  await pool.query('DELETE FROM scan_step_attempts WHERE scan_id = ANY($1)', [scanIds]);
  await pool.query('DELETE FROM scans WHERE id = ANY($1)', [scanIds]);
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

  it('declare for a non-existent step attempt -> 422 DS_UPLOAD_002', async () => {
    const scan = await mkScan();
    const r = await declare(scan, 'neutral_face', 'video', 'a', 2);
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

  it('enqueue called exactly once after last core artefact', async () => {
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
    // Re-completing an already verified artefact does not enqueue again.
    const id = (await pool.query(`SELECT id FROM artefacts WHERE scan_id = $1 AND kind = 'roi_trace' AND step = 'fingertip_ppg'`, [scan])).rows[0].id;
    expect((await post(`/v1/artefacts/${id}/complete`)).statusCode).toBe(200);
    expect(count()).toBe(1);
  });

  it('two concurrent final completes enqueue once', async () => {
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
    expect(ta.fakes.qualityQueue.enqueued.filter((x) => x === scan)).toHaveLength(1);
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
      `SELECT count(*)::int AS n FROM clinical_audit_log WHERE event_type = 'device_event' AND resource_id = $1`,
      [id],
    )).rows[0].n;
    expect(ev).toBe(1);
  });

  it('rejects unknown fields and bad sha256 -> 400', async () => {
    const scan = await mkScan();
    const base = { step: 'neutral_face', attempt: 1, kind: 'video', size_bytes: 10, sha256: sha('a') };
    expect((await post(`/v1/scans/${scan}/artefacts`, { ...base, extra: 1 })).statusCode).toBe(400);
    expect((await post(`/v1/scans/${scan}/artefacts`, { ...base, sha256: 'abc' })).statusCode).toBe(400);
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
