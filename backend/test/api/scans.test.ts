import { randomUUID } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { getTestPool } from '../pg';
import { seedFixtures, clearFixtures, SITE_A, SITE_B, CONSENT_VERSION, PATIENT_B, SCAN_B } from '../fixtures';
import { buildTestApp, tokenFor, deviceTokenFor, bearer } from './helpers';

const pool = getTestPool();
let app: FastifyInstance;

// Test patients (site A) — one per consent situation.
const P_OK = '00000000-0000-4000-a000-0000000005a1';
const P_OK2 = '00000000-0000-4000-a000-0000000005a2';
const P_RACE = '00000000-0000-4000-a000-0000000005a3';
const P_WITHDRAWN = '00000000-0000-4000-a000-0000000005b1';
const P_SUPERSEDED = '00000000-0000-4000-a000-0000000005b2';
const P_NO_PRIMARY = '00000000-0000-4000-a000-0000000005b3';
const P_NO_CONSENT = '00000000-0000-4000-a000-0000000005b4';
// Consents valid at creation, withdrawn / superseded afterwards (post-hoc re-check).
const P_LATE_1 = '00000000-0000-4000-a000-0000000005c1';
const P_LATE_2 = '00000000-0000-4000-a000-0000000005c2';
const ALL = [P_OK, P_OK2, P_RACE, P_WITHDRAWN, P_SUPERSEDED, P_NO_PRIMARY, P_NO_CONSENT, P_LATE_1, P_LATE_2];
const OLD_VERSION = 'rls-v0-scans';

const T0 = Date.parse('2026-10-01T08:00:00Z');
const at = (min: number) => new Date(T0 + min * 60_000).toISOString();

const STEPS = ['neutral_face', 'fingertip_ppg', 'ocular_capture', 'dorsal_tongue'] as const;

const metadata = {
  camera_model: 'iPhone15,3',
  frame_rate: 60,
  resolution: '1920x1080',
  exposure: 0.5,
  distance_cm: 40,
  angle_deg: 0,
  lighting_lux: 500,
  ambient_temp_c: 27,
  ambient_humidity_pct: 70,
  mount: 'holder',
  lighting_type: 'led_ring',
  exposure_duration_ms: 8,
};

const scanBody = (o: Record<string, unknown> = {}) => ({
  client_session_id: randomUUID(),
  patient_id: P_OK,
  captured_at: at(0),
  offline: false,
  protocol_version: 'p1',
  capture_steps: [...STEPS],
  device_attempts: STEPS.map((step) => ({ step, attempt: 1, device_verdict: 'ACCEPT', reason_codes: [] })),
  metadata,
  ...o,
});

const post = async (url: string, body: unknown, o: { key?: string; role?: string; site?: string } = {}) =>
  app.inject({
    method: 'POST',
    url,
    headers: { ...bearer(await tokenFor(o.role ?? 'nurse_operator', o.site ?? SITE_A)), 'idempotency-key': o.key ?? randomUUID() },
    payload: body as object,
  });

const getScan = async (id: string, token?: string) =>
  app.inject({ method: 'GET', url: `/v1/scans/${id}`, headers: bearer(token ?? (await tokenFor('nurse_operator', SITE_A))) });

beforeAll(async () => {
  await seedFixtures(pool);
  ({ app } = await buildTestApp());
  await pool.query(
    `INSERT INTO patients(id,participant_code,pseudonym_id,site_id,bed_label,cohort)
     SELECT id, 'DS-RLSA-' || lpad((500 + n)::text, 5, '0'), 'ps-scan-' || n, $2, 'S-' || n, 'dengue'
       FROM unnest($1::uuid[]) WITH ORDINALITY AS t(id, n)
     ON CONFLICT DO NOTHING`,
    [ALL, SITE_A],
  );
  await pool.query(`INSERT INTO consent_versions(version,is_current) VALUES ($1,false) ON CONFLICT DO NOTHING`, [OLD_VERSION]);
  await pool.query(
    `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at,withdrawn_at)
     VALUES ($1,$5,true,now() - interval '2 days',NULL),
            ($2,$5,true,now() - interval '2 days',NULL),
            ($3,$5,true,now() - interval '2 days',NULL),
            ($4,$5,false,now() - interval '2 days',NULL),
            ($6,$5,true,now() - interval '2 days',NULL),
            ($7,$5,true,now() - interval '2 days',NULL)`,
    [P_OK, P_OK2, P_RACE, P_NO_PRIMARY, CONSENT_VERSION, P_LATE_1, P_LATE_2],
  );
  // Withdrawn: consented, then a later (recorded_at) row records the withdrawal.
  await pool.query(
    `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at) VALUES ($1,$2,true,now() - interval '2 days')`,
    [P_WITHDRAWN, CONSENT_VERSION],
  );
  await pool.query(
    `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at,withdrawn_at)
     VALUES ($1,$2,true,now() - interval '2 days',now())`,
    [P_WITHDRAWN, CONSENT_VERSION],
  );
  await pool.query(
    `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at) VALUES ($1,$2,true,now() - interval '2 days')`,
    [P_SUPERSEDED, OLD_VERSION],
  );
});

afterAll(async () => {
  await app.close();
  await pool.query(
    'DELETE FROM scan_step_attempts WHERE scan_id IN (SELECT id FROM scans WHERE patient_id = ANY($1))',
    [ALL],
  );
  await pool.query('DELETE FROM scans WHERE patient_id = ANY($1)', [ALL]);
  await pool.query('DELETE FROM consents WHERE patient_id = ANY($1)', [ALL]);
  await pool.query('DELETE FROM patients WHERE id = ANY($1)', [ALL]);
  await pool.query('DELETE FROM consent_versions WHERE version = $1', [OLD_VERSION]);
  await clearFixtures(pool);
  await pool.end();
});

const countScans = async (patientId: string) =>
  Number((await pool.query('SELECT count(*) FROM scans WHERE patient_id = $1', [patientId])).rows[0].count);

describe('POST /v1/scans', () => {
  it('creates scan 201', async () => {
    const b = scanBody();
    const r = await post('/v1/scans', b);
    expect(r.statusCode).toBe(201);
    const s = r.json().scan;
    expect(s).toEqual({ id: expect.any(String), status: 'capture_pending', client_session_id: b.client_session_id });
    const row = (await pool.query('SELECT * FROM scans WHERE id = $1', [s.id])).rows[0];
    expect(row).toMatchObject({
      patient_id: P_OK,
      site_id: SITE_A,
      device_id: null,
      operator_user_id: 'rls-nurse_operator',
      offline: false,
      protocol_version: 'p1',
      status: 'capture_pending',
    });
    expect(new Date(row.captured_at).toISOString()).toBe(b.captured_at);
    expect(row.metadata).toMatchObject({ mount: 'holder', capture_steps: [...STEPS] });
    const att = await pool.query('SELECT step, attempt FROM scan_step_attempts WHERE scan_id = $1', [s.id]);
    expect(att.rowCount).toBe(4);
    const a = await pool.query(
      `SELECT event_type, resource_type, patient_pseudonym, outcome FROM clinical_audit_log
        WHERE resource_id = $1 AND resource_type = 'scan' ORDER BY id DESC LIMIT 1`,
      [s.id],
    );
    expect(a.rows[0]).toEqual({ event_type: 'clinician_action', resource_type: 'scan', patient_pseudonym: 'ps-scan-1', outcome: 'scan:create' });
  });

  it('ambient_temp_c / ambient_humidity_pct are optional (spec 9: if entered) → 201', async () => {
    const { ambient_temp_c: _t, ambient_humidity_pct: _h, ...noAmbient } = metadata;
    const r = await post('/v1/scans', scanBody({ captured_at: at(5000), metadata: noAmbient }));
    expect(r.statusCode).toBe(201);
    const row = (await pool.query('SELECT metadata FROM scans WHERE id = $1', [r.json().scan.id])).rows[0];
    expect(row.metadata.ambient_temp_c).toBeUndefined();
    const bad = await post('/v1/scans', scanBody({ captured_at: at(6000), metadata: { ...metadata, ambient_humidity_pct: 120 } }));
    expect(bad.statusCode).toBe(400);
  });

  it('metadata ranges are physical sanity only; server stores metadata_in_spec (T13 ruling)', async () => {
    const inSpec = await post('/v1/scans', scanBody({ captured_at: at(7000) }));
    expect(inSpec.statusCode).toBe(201);
    const row1 = (await pool.query('SELECT metadata FROM scans WHERE id = $1', [inSpec.json().scan.id])).rows[0];
    expect(row1.metadata.metadata_in_spec).toBe(true);

    const out = await post(
      '/v1/scans',
      scanBody({ captured_at: at(8000), metadata: { ...metadata, distance_cm: 100, angle_deg: -30, lighting_lux: 50 } }),
    );
    expect(out.statusCode).toBe(201);
    const row2 = (await pool.query('SELECT metadata FROM scans WHERE id = $1', [out.json().scan.id])).rows[0];
    expect(row2.metadata).toMatchObject({ distance_cm: 100, angle_deg: -30, lighting_lux: 50, metadata_in_spec: false });

    for (const [i, bad] of [{ distance_cm: 4 }, { distance_cm: 301 }, { angle_deg: 91 }, { angle_deg: -91 },
      { lighting_lux: -1 }, { metadata_in_spec: true }].entries()) {
      const r = await post('/v1/scans', scanBody({ captured_at: at(9000 + i * 100), metadata: { ...metadata, ...bad } }));
      expect(r.statusCode, JSON.stringify(bad)).toBe(400);
    }
  });

  it('metadata_in_spec boundaries: 20/80 cm, |15| deg, 200 lx are in spec', async () => {
    const edge = await post(
      '/v1/scans',
      scanBody({ captured_at: at(10000), metadata: { ...metadata, distance_cm: 80, angle_deg: -15, lighting_lux: 200 } }),
    );
    expect(edge.statusCode).toBe(201);
    const row = (await pool.query('SELECT metadata FROM scans WHERE id = $1', [edge.json().scan.id])).rows[0];
    expect(row.metadata.metadata_in_spec).toBe(true);
    const below = await post(
      '/v1/scans',
      scanBody({ captured_at: at(11000), metadata: { ...metadata, distance_cm: 19.9 } }),
    );
    const row2 = (await pool.query('SELECT metadata FROM scans WHERE id = $1', [below.json().scan.id])).rows[0];
    expect(row2.metadata.metadata_in_spec).toBe(false);
  });

  it('I4: distance_cm / angle_deg / lighting_lux are optional (no face detected); metadata_in_spec is then false', async () => {
    const { distance_cm: _d, angle_deg: _a, lighting_lux: _l, ...noFace } = metadata;
    const r = await post('/v1/scans', scanBody({ captured_at: at(12000), metadata: noFace }));
    expect(r.statusCode).toBe(201);
    const row = (await pool.query('SELECT metadata FROM scans WHERE id = $1', [r.json().scan.id])).rows[0];
    expect(row.metadata.distance_cm).toBeUndefined();
    expect(row.metadata.metadata_in_spec).toBe(false);
    for (const [i, k] of (['distance_cm', 'angle_deg', 'lighting_lux'] as const).entries()) {
      const { [k]: _omit, ...one } = metadata;
      const r1 = await post('/v1/scans', scanBody({ captured_at: at(13000 + i * 100), metadata: one }));
      expect(r1.statusCode).toBe(201);
      const m = (await pool.query('SELECT metadata FROM scans WHERE id = $1', [r1.json().scan.id])).rows[0].metadata;
      expect(m.metadata_in_spec, k).toBe(false);
    }
  });

  it('same client_session_id returns 200 same id', async () => {
    const b = scanBody({ patient_id: P_OK2, captured_at: at(0) });
    const first = await post('/v1/scans', b);
    expect(first.statusCode).toBe(201);
    const again = await post('/v1/scans', b); // new Idempotency-Key, same session
    expect(again.statusCode).toBe(200);
    expect(again.json().scan).toEqual(first.json().scan);
    expect(await countScans(P_OK2)).toBe(1);
  });

  it('second scan 20 min later → 409 DS_SCAN_001 (either direction)', async () => {
    const later = await post('/v1/scans', scanBody({ captured_at: at(20) }));
    expect(later.statusCode).toBe(409);
    expect(later.json().error.code).toBe('DS_SCAN_001');
    const earlier = await post('/v1/scans', scanBody({ captured_at: at(-20) }));
    expect(earlier.statusCode).toBe(409);
    expect(earlier.json().error.code).toBe('DS_SCAN_001');
  });

  it('scan captured 40 min later → 201', async () => {
    const r = await post('/v1/scans', scanBody({ captured_at: at(40) }));
    expect(r.statusCode).toBe(201);
  });

  it('revoked scans do not count for the 30-min rule', async () => {
    const r = await post('/v1/scans', scanBody({ captured_at: at(200) }));
    expect(r.statusCode).toBe(201);
    await pool.query(`UPDATE scans SET status='revoked' WHERE id=$1`, [r.json().scan.id]);
    expect((await post('/v1/scans', scanBody({ captured_at: at(210) }))).statusCode).toBe(201);
  });

  it('withdrawn consent offline → 451 DS_REG_001 and audit row capture_rejected_post_hoc', async () => {
    const b = scanBody({ patient_id: P_WITHDRAWN, offline: true });
    const r = await post('/v1/scans', b);
    expect(r.statusCode).toBe(451);
    expect(r.json().error.code).toBe('DS_REG_001');
    expect(await countScans(P_WITHDRAWN)).toBe(0);
    const a = await pool.query(
      `SELECT event_type, patient_pseudonym, resource_type, outcome FROM clinical_audit_log
        WHERE event_type='capture_rejected_post_hoc' AND resource_id=$1`,
      [b.client_session_id],
    );
    expect(a.rows).toEqual([
      { event_type: 'capture_rejected_post_hoc', patient_pseudonym: 'ps-scan-4', resource_type: 'scan', outcome: 'DS_REG_001' },
    ]);
  });

  it('withdrawn consent online → 451 DS_REG_001 without post-hoc audit row', async () => {
    const b = scanBody({ patient_id: P_WITHDRAWN, offline: false });
    const r = await post('/v1/scans', b);
    expect(r.statusCode).toBe(451);
    expect(r.json().error.code).toBe('DS_REG_001');
    const a = await pool.query(
      `SELECT 1 FROM clinical_audit_log WHERE event_type='capture_rejected_post_hoc' AND resource_id=$1`,
      [b.client_session_id],
    );
    expect(a.rowCount).toBe(0);
  });

  it('superseded → 451 DS_REG_002', async () => {
    const r = await post('/v1/scans', scanBody({ patient_id: P_SUPERSEDED, offline: true }));
    expect(r.statusCode).toBe(451);
    expect(r.json().error.code).toBe('DS_REG_002');
    expect(await countScans(P_SUPERSEDED)).toBe(0);
  });

  it('no primary_research or no consent row → 451 DS_REG_001', async () => {
    for (const p of [P_NO_PRIMARY, P_NO_CONSENT]) {
      const r = await post('/v1/scans', scanBody({ patient_id: p }));
      expect(r.statusCode).toBe(451);
      expect(r.json().error.code).toBe('DS_REG_001');
    }
  });

  it('cross-site / unknown patient → 404; researcher → 403; device → 403', async () => {
    const x = await post('/v1/scans', scanBody({ patient_id: PATIENT_B }));
    expect(x.statusCode).toBe(404);
    expect(x.json().error.code).toBe('DS_NOT_FOUND');
    expect((await post('/v1/scans', scanBody({ patient_id: P_OK }), { site: SITE_B })).statusCode).toBe(404);
    expect((await post('/v1/scans', scanBody({ patient_id: randomUUID() }))).statusCode).toBe(404);
    expect((await post('/v1/scans', scanBody(), { role: 'researcher' })).statusCode).toBe(403);
    const d = await app.inject({
      method: 'POST',
      url: '/v1/scans',
      headers: { ...bearer(await deviceTokenFor(randomUUID(), SITE_A)), 'idempotency-key': randomUUID() },
      payload: scanBody(),
    });
    expect(d.statusCode).toBe(403);
  });

  it('validation: unknown field, bad step, attempt > 3, duplicate attempts, step not captured → 400', async () => {
    const bad = [
      scanBody({ extra: 1 }),
      scanBody({ metadata: { ...metadata, name: 'x' } }),
      scanBody({ capture_steps: ['identity_check'] }),
      scanBody({ device_attempts: [{ step: 'neutral_face', attempt: 4, device_verdict: 'ACCEPT', reason_codes: [] }] }),
      scanBody({
        device_attempts: [
          { step: 'neutral_face', attempt: 1, device_verdict: 'ACCEPT', reason_codes: [] },
          { step: 'neutral_face', attempt: 1, device_verdict: 'RECAPTURE', reason_codes: [] },
        ],
      }),
      scanBody({
        capture_steps: ['neutral_face'],
        device_attempts: [{ step: 'fingertip_ppg', attempt: 1, device_verdict: 'ACCEPT', reason_codes: [] }],
      }),
      scanBody({ captured_at: 'yesterday' }),
      scanBody({ capture_steps: ['neutral_face'], device_attempts: [] }),
      scanBody({ capture_steps: ['fingertip_ppg', 'ocular_capture'], device_attempts: [] }),
    ];
    for (const b of bad) {
      const r = await post('/v1/scans', b);
      expect(r.statusCode, JSON.stringify(b)).toBe(400);
      expect(r.json().error.code).toBe('DS_VALIDATION_001');
    }
  });

  it('missing Idempotency-Key → 400 DS_IDEMPOTENCY_002', async () => {
    const r = await app.inject({
      method: 'POST',
      url: '/v1/scans',
      headers: bearer(await tokenFor('nurse_operator', SITE_A)),
      payload: scanBody(),
    });
    expect(r.statusCode).toBe(400);
    expect(r.json().error.code).toBe('DS_IDEMPOTENCY_002');
  });

  it('existing client_session_id after withdrawal → 451 DS_REG_001 with committed post-hoc audit', async () => {
    const b = scanBody({ patient_id: P_LATE_1, captured_at: at(0) });
    const first = await post('/v1/scans', b);
    expect(first.statusCode).toBe(201);
    await pool.query(
      `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at,withdrawn_at)
       VALUES ($1,$2,true,now() - interval '2 days',now())`,
      [P_LATE_1, CONSENT_VERSION],
    );
    const again = await post('/v1/scans', b); // fresh Idempotency-Key: the 200 replay path
    expect(again.statusCode).toBe(451);
    expect(again.json().error.code).toBe('DS_REG_001');
    const a = await pool.query(
      `SELECT patient_pseudonym, resource_type, outcome FROM clinical_audit_log
        WHERE event_type='capture_rejected_post_hoc' AND resource_id=$1`,
      [first.json().scan.id],
    );
    expect(a.rows).toEqual([{ patient_pseudonym: 'ps-scan-8', resource_type: 'scan', outcome: 'DS_REG_001' }]);
  });

  it('two parallel identical POSTs (same Idempotency-Key) → one row, two identical responses', async () => {
    const b = scanBody({ patient_id: P_RACE, captured_at: at(0) });
    const key = randomUUID();
    const [r1, r2] = await Promise.all([post('/v1/scans', b, { key }), post('/v1/scans', b, { key })]);
    expect(r1.statusCode).toBe(201);
    expect(r2.statusCode).toBe(201);
    expect(r2.json()).toEqual(r1.json());
    expect(await countScans(P_RACE)).toBe(1);
  });

  it('two parallel POSTs with different keys but the same client_session_id → one scan', async () => {
    const b = scanBody({ patient_id: P_RACE, captured_at: at(100) });
    const [r1, r2] = await Promise.all([post('/v1/scans', b), post('/v1/scans', b)]);
    expect([r1.statusCode, r2.statusCode].sort()).toEqual([200, 201]);
    expect(r1.json().scan.id).toBe(r2.json().scan.id);
    expect(
      Number((await pool.query('SELECT count(*) FROM scans WHERE client_session_id = $1', [b.client_session_id])).rows[0].count),
    ).toBe(1);
  });

  it('two parallel POSTs, different sessions within 30 min → one 201, one 409', async () => {
    const [r1, r2] = await Promise.all([
      post('/v1/scans', scanBody({ patient_id: P_RACE, captured_at: at(300) })),
      post('/v1/scans', scanBody({ patient_id: P_RACE, captured_at: at(310) })),
    ]);
    expect([r1.statusCode, r2.statusCode].sort()).toEqual([201, 409]);
  });
});

describe('GET /v1/scans/:id and POST /v1/scans/:id/recapture', () => {
  const recapture = (id: string, steps: string[], key?: string) =>
    post(`/v1/scans/${id}/recapture`, { steps, trigger_reason_code: 'SQI_PPG_LOW' }, { key });

  const newScan = async (minute: number) => {
    const r = await post('/v1/scans', scanBody({ patient_id: P_OK2, captured_at: at(minute) }));
    expect(r.statusCode).toBe(201);
    return r.json().scan.id as string;
  };

  it('GET returns steps and recaptures_remaining', async () => {
    const id = await newScan(1000);
    const r = await getScan(id);
    expect(r.statusCode).toBe(200);
    const s = r.json().scan;
    expect(s.id).toBe(id);
    expect(s.status).toBe('capture_pending');
    expect(s.steps).toHaveLength(4);
    expect(s.steps[0]).toEqual({
      step: expect.any(String),
      attempt: 1,
      device_verdict: 'ACCEPT',
      server_verdict: null,
      reason_codes: [],
    });
    expect(s.recaptures_remaining).toEqual({ neutral_face: 2, fingertip_ppg: 2, ocular_capture: 2, dorsal_tongue: 2 });
  });

  it('GET other-site / unknown scan → 404; researcher → 403', async () => {
    expect((await getScan(SCAN_B)).statusCode).toBe(404);
    expect((await getScan(randomUUID())).statusCode).toBe(404);
    expect((await getScan(randomUUID(), await tokenFor('researcher'))).statusCode).toBe(403);
  });

  it('GET with a device token of the same site → 200', async () => {
    const id = await newScan(1100);
    const r = await getScan(id, await deviceTokenFor(randomUUID(), SITE_A));
    expect(r.statusCode).toBe(200);
    expect(r.json().scan.id).toBe(id);
    expect(r.json().scan.steps).toHaveLength(4);
    expect(r.json().scan.recaptures_remaining).toEqual({ neutral_face: 2, fingertip_ppg: 2, ocular_capture: 2, dorsal_tongue: 2 });
    expect((await getScan(id, await deviceTokenFor(randomUUID(), SITE_B))).statusCode).toBe(404);
  });

  it('recapture fingertip twice ok, third → 422 DS_QG_099 and status acquisition_failure', async () => {
    const id = await newScan(1200);
    const r1 = await recapture(id, ['fingertip_ppg']);
    expect(r1.statusCode).toBe(200);
    expect(r1.json().scan.recaptures_remaining.fingertip_ppg).toBe(1);
    const r2 = await recapture(id, ['fingertip_ppg']);
    expect(r2.statusCode).toBe(200);
    expect(r2.json().scan.recaptures_remaining.fingertip_ppg).toBe(0);
    const r3 = await recapture(id, ['fingertip_ppg']);
    expect(r3.statusCode).toBe(422);
    expect(r3.json().error.code).toBe('DS_QG_099');
    expect(r3.json().error.detail).toEqual({ unable_to_acquire: ['fingertip_ppg'], recaptured: [], status: 'acquisition_failure' });
    const g = (await getScan(id)).json().scan;
    expect(g.status).toBe('acquisition_failure');
    expect(g.steps.filter((s: { step: string }) => s.step === 'fingertip_ppg').map((s: { attempt: number }) => s.attempt)).toEqual([1, 2, 3]);
    const row = (await pool.query('SELECT status, metadata FROM scans WHERE id=$1', [id])).rows[0];
    expect(row.metadata.unable_to_acquire).toEqual(['fingertip_ppg']);
  });

  it('non-core step exhausted → 422 DS_QG_099, scan status unchanged', async () => {
    const id = await newScan(1300);
    expect((await recapture(id, ['dorsal_tongue'])).statusCode).toBe(200);
    expect((await recapture(id, ['dorsal_tongue'])).statusCode).toBe(200);
    const r = await recapture(id, ['dorsal_tongue']);
    expect(r.statusCode).toBe(422);
    expect(r.json().error.code).toBe('DS_QG_099');
    expect((await getScan(id)).json().scan.status).toBe('capture_pending');
  });

  it('optional step exhausted + recapturable step → 422, other step still recaptured, status unchanged', async () => {
    const id = await newScan(1350);
    expect((await recapture(id, ['dorsal_tongue'])).statusCode).toBe(200);
    expect((await recapture(id, ['dorsal_tongue'])).statusCode).toBe(200);
    const r = await recapture(id, ['dorsal_tongue', 'ocular_capture']);
    expect(r.statusCode).toBe(422);
    expect(r.json().error.code).toBe('DS_QG_099');
    expect(r.json().error.detail).toEqual({ unable_to_acquire: ['dorsal_tongue'], recaptured: ['ocular_capture'], status: 'capture_pending' });
    const g = (await getScan(id)).json().scan;
    expect(g.status).toBe('capture_pending');
    const by = (step: string) => g.steps.filter((x: { step: string }) => x.step === step).map((x: { attempt: number }) => x.attempt);
    expect(by('ocular_capture')).toEqual([1, 2]);
    expect(by('dorsal_tongue')).toEqual([1, 2, 3]);
    expect(g.recaptures_remaining).toMatchObject({ ocular_capture: 1, dorsal_tongue: 0 });
  });

  it('core step exhausted from quality_failed → acquisition_failure, no other attempts added', async () => {
    const id = await newScan(1800);
    expect((await recapture(id, ['neutral_face'])).statusCode).toBe(200);
    expect((await recapture(id, ['neutral_face'])).statusCode).toBe(200);
    await pool.query(`UPDATE scans SET status='quality_pending' WHERE id=$1`, [id]);
    await pool.query(`UPDATE scans SET status='quality_failed' WHERE id=$1`, [id]);
    const r = await recapture(id, ['neutral_face', 'ocular_capture']);
    expect(r.statusCode).toBe(422);
    expect(r.json().error.detail).toEqual({ unable_to_acquire: ['neutral_face'], recaptured: [], status: 'acquisition_failure' });
    const g = (await getScan(id)).json().scan;
    expect(g.status).toBe('acquisition_failure');
    expect(g.steps.filter((x: { step: string }) => x.step === 'ocular_capture')).toHaveLength(1);
  });

  it('repeating an already-recorded failure writes no extra audit row', async () => {
    const id = await newScan(1850);
    expect((await recapture(id, ['dorsal_tongue'])).statusCode).toBe(200);
    expect((await recapture(id, ['dorsal_tongue'])).statusCode).toBe(200);
    expect((await recapture(id, ['dorsal_tongue'])).statusCode).toBe(422);
    const n = async () =>
      Number((await pool.query(`SELECT count(*) FROM clinical_audit_log WHERE resource_id=$1 AND outcome='DS_QG_099'`, [id])).rows[0].count);
    expect(await n()).toBe(1);
    expect((await recapture(id, ['dorsal_tongue'])).statusCode).toBe(422);
    expect(await n()).toBe(1);
  });

  it('recapture only ocular step leaves face attempts unchanged', async () => {
    const id = await newScan(1400);
    const r = await recapture(id, ['ocular_capture']);
    expect(r.statusCode).toBe(200);
    const s = r.json().scan;
    const by = (step: string) => s.steps.filter((x: { step: string }) => x.step === step).map((x: { attempt: number }) => x.attempt);
    expect(by('ocular_capture')).toEqual([1, 2]);
    expect(by('neutral_face')).toEqual([1]);
    expect(s.recaptures_remaining).toEqual({ neutral_face: 2, fingertip_ppg: 2, ocular_capture: 1, dorsal_tongue: 2 });
    const added = s.steps.find((x: { step: string; attempt: number }) => x.step === 'ocular_capture' && x.attempt === 2);
    expect(added.reason_codes).toEqual(['SQI_PPG_LOW']);
  });

  it('recapture after re-consent to a superseded version → 451 DS_REG_002, nothing recaptured, audited', async () => {
    const r0 = await post('/v1/scans', scanBody({ patient_id: P_LATE_2, captured_at: at(0) }));
    expect(r0.statusCode).toBe(201);
    const id = r0.json().scan.id;
    await pool.query(
      `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at) VALUES ($1,$2,true,now())`,
      [P_LATE_2, OLD_VERSION],
    );
    const r = await recapture(id, ['ocular_capture']);
    expect(r.statusCode).toBe(451);
    expect(r.json().error.code).toBe('DS_REG_002');
    expect((await getScan(id)).json().scan.recaptures_remaining.ocular_capture).toBe(2);
    const a = await pool.query(
      `SELECT patient_pseudonym, outcome FROM clinical_audit_log WHERE event_type='capture_rejected_post_hoc' AND resource_id=$1`,
      [id],
    );
    expect(a.rows).toEqual([{ patient_pseudonym: 'ps-scan-9', outcome: 'DS_REG_002' }]);
  });

  it('recapture from quality_failed returns the scan to capture_pending', async () => {
    const id = await newScan(1500);
    await pool.query(`UPDATE scans SET status='quality_pending' WHERE id=$1`, [id]);
    await pool.query(`UPDATE scans SET status='quality_failed' WHERE id=$1`, [id]);
    const r = await recapture(id, ['neutral_face']);
    expect(r.statusCode).toBe(200);
    expect(r.json().scan.status).toBe('capture_pending');
  });

  it('recapture in a non-recapturable state → 409 DS_STATE_001; other site → 404; step not captured → 400', async () => {
    const id = await newScan(1600);
    await pool.query(`UPDATE scans SET status='quality_pending' WHERE id=$1`, [id]);
    const r = await recapture(id, ['neutral_face']);
    expect(r.statusCode).toBe(409);
    expect(r.json().error.code).toBe('DS_STATE_001');
    expect((await recapture(SCAN_B, ['neutral_face'])).statusCode).toBe(404);
    expect((await recapture(id, ['identity_check'])).statusCode).toBe(400);
    const narrow = await post('/v1/scans', scanBody({
      patient_id: P_OK2,
      captured_at: at(1700),
      capture_steps: ['neutral_face', 'fingertip_ppg'],
      device_attempts: [{ step: 'neutral_face', attempt: 1, device_verdict: 'ACCEPT', reason_codes: [] }],
    }));
    expect(narrow.statusCode).toBe(201);
    const nr = await recapture(narrow.json().scan.id, ['ocular_capture']);
    expect(nr.statusCode).toBe(400);
    expect(nr.json().error.code).toBe('DS_VALIDATION_001');
  });
});
