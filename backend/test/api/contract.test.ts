// F10: every route's happy path, with each success body validated against its published R.* schema
// (expectContract). The last test asserts that every documented route/status was exercised.
import { createHash, randomUUID } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { getTestPool } from '../pg';
import { seedFixtures, clearFixtures, SITE_A, PATIENT_A } from '../fixtures';
import { buildTestApp, tokenFor, bearer, type TestApp } from './helpers';
import { R, ROUTE_DOCS } from '../../src/openapi';
import { allDocumentedSuccesses, contractCovered, expectContract } from './contract';

const pool = getTestPool();
let t: TestApp;
let app: FastifyInstance;

const WARD = 'CT-W1';
const sha = (s: string) => createHash('sha256').update(s).digest('hex');
const b64 = (s: string) => Buffer.from(s).toString('base64');

const nurse = () => tokenFor('nurse_operator', SITE_A);
const clinician = () => tokenFor('clinician', SITE_A);

const get = async (url: string, token?: string) =>
  app.inject({ method: 'GET', url, headers: token === '' ? {} : bearer(token ?? (await nurse())) });
const post = async (url: string, body: unknown, token?: string | null, idem = true) =>
  app.inject({
    method: 'POST',
    url,
    headers: {
      ...(token === null ? {} : bearer(token ?? (await nurse()))),
      ...(idem ? { 'idempotency-key': randomUUID() } : {}),
    },
    payload: body as object,
  });

const metadata = {
  camera_model: 'iPhone15,3', frame_rate: 60, resolution: '1920x1080', exposure: 0.5, distance_cm: 40,
  angle_deg: 0, lighting_lux: 500, ambient_temp_c: 27, ambient_humidity_pct: 70, mount: 'holder',
  lighting_type: 'led_ring', exposure_duration_ms: 8,
};

let scanId = '';
let deviceId = '';
let deviceToken = '';
const scanBody = {
  client_session_id: randomUUID(),
  patient_id: PATIENT_A,
  captured_at: '2024-06-01T08:00:00Z',
  offline: false,
  protocol_version: 'p1',
  capture_steps: ['neutral_face', 'fingertip_ppg', 'ocular_capture'],
  device_attempts: ['neutral_face', 'fingertip_ppg', 'ocular_capture'].map((step) => ({
    step, attempt: 1, device_verdict: 'ACCEPT', reason_codes: [],
  })),
  metadata,
};

beforeAll(async () => {
  await seedFixtures(pool);
  await pool.query('INSERT INTO wards(id, site_id) VALUES ($1,$2) ON CONFLICT DO NOTHING', [WARD, SITE_A]);
  await pool.query('UPDATE patients SET ward_id = $2 WHERE id = $1', [PATIENT_A, WARD]);
  t = await buildTestApp();
  app = t.app;
});

afterAll(async () => {
  await app.close();
  if (scanId) {
    for (const tbl of ['features', 'scan_reviews', 'review_challenges', 'artefacts', 'scan_step_attempts']) {
      await pool.query(`DELETE FROM ${tbl} WHERE scan_id = $1`, [scanId]);
    }
    await pool.query('DELETE FROM scans WHERE id = $1', [scanId]);
  }
  await pool.query('DELETE FROM clinical_observations WHERE patient_id = $1', [PATIENT_A]);
  await pool.query('DELETE FROM lab_values WHERE patient_id = $1', [PATIENT_A]);
  await pool.query('DELETE FROM site_protocol_flags WHERE site_id = $1', [SITE_A]);
  await pool.query('UPDATE patients SET ward_id = NULL WHERE id = $1', [PATIENT_A]);
  await clearFixtures(pool);
});

describe('response contracts (happy paths)', () => {
  it('every ROUTE_DOCS success schema is one of the exported R.* schemas', () => {
    const published = new Set<unknown>(Object.values(R));
    for (const [k, d] of Object.entries(ROUTE_DOCS)) {
      for (const s of Object.values(d.ok)) if (s !== null) expect(published.has(s), k).toBe(true);
    }
  });

  it('health and patient reads', async () => {
    expectContract(await get('/health', ''), 'GET', '/health');
    expectContract(await get('/v1/patients/lookup?participant_code=DS-RLSA-00001'), 'GET', '/v1/patients/lookup');
    expectContract(await get(`/v1/wards/${WARD}/roster`), 'GET', '/v1/wards/{wardId}/roster');
    expectContract(await get(`/v1/patients/${PATIENT_A}/consent-status`), 'GET', '/v1/patients/{id}/consent-status');
  });

  it('clinical data', async () => {
    const r = await post(`/v1/patients/${PATIENT_A}/clinical-data`, {
      observations: [{
        observation_id: randomUUID(), vital: 'temp_c', value: 38.5, unit: '°C',
        source_device_type: 'thermometer', measured_at: new Date().toISOString(),
      }],
      labs: [{
        id: randomUUID(), test: 'platelet_count', value: 90, unit: '10^9/L',
        collected_at: new Date().toISOString(), methodology: 'analyser',
      }],
    });
    expectContract(r, 'POST', '/v1/patients/{id}/clinical-data');
  });

  it('devices: challenge, attest, assert, renewal challenge, push token', async () => {
    const ch = expectContract(await post('/v1/devices/challenge', {}, await clinician()), 'POST', '/v1/devices/challenge');
    const at = expectContract(await post('/v1/devices/attest', {
      key_id: `ct-${randomUUID()}`, attestation: b64('attestation'), challenge: ch.json().challenge, ward_id: WARD,
    }, await clinician()), 'POST', '/v1/devices/attest');
    deviceId = at.json().device_id;
    const ch2 = await post('/v1/devices/challenge', {}, await clinician());
    const as = expectContract(await post('/v1/devices/assert', {
      device_id: deviceId, assertion: b64('1'), challenge: ch2.json().challenge,
    }, await clinician(), false), 'POST', '/v1/devices/assert');
    deviceToken = as.json().device_token;
    expectContract(await post(`/v1/devices/${deviceId}/renewal-challenge`, {}, null, false), 'POST', '/v1/devices/{id}/renewal-challenge');
    expectContract(await post('/v1/devices/push-token', { device_id: deviceId, apns_token: 'ab'.repeat(32) }, deviceToken),
      'POST', '/v1/devices/push-token');
  });

  it('scans: create (201), replay (200), read (user and device), recapture', async () => {
    const created = expectContract(await post('/v1/scans', scanBody), 'POST', '/v1/scans');
    expect(created.statusCode).toBe(201);
    scanId = created.json().scan.id;
    expect(expectContract(await post('/v1/scans', scanBody), 'POST', '/v1/scans').statusCode).toBe(200);
    expectContract(await get(`/v1/scans/${scanId}`), 'GET', '/v1/scans/{id}');
    expectContract(await get(`/v1/scans/${scanId}`, deviceToken), 'GET', '/v1/scans/{id}');
    expectContract(await post(`/v1/scans/${scanId}/recapture`, { steps: ['ocular_capture'], trigger_reason_code: 'SQI_LOW' }),
      'POST', '/v1/scans/{id}/recapture');
  });

  it('artefacts: declare (201, 200), part url, complete -> quality_pending', async () => {
    for (const step of ['neutral_face', 'fingertip_ppg']) {
      for (const kind of ['video', 'roi_trace']) {
        const body = { step, attempt: 1, kind, size_bytes: 10, sha256: sha(`${step}-${kind}`) };
        const d = expectContract(await post(`/v1/scans/${scanId}/artefacts`, body, deviceToken), 'POST', '/v1/scans/{id}/artefacts');
        expect(d.statusCode).toBe(201);
        expect(expectContract(await post(`/v1/scans/${scanId}/artefacts`, body, deviceToken), 'POST', '/v1/scans/{id}/artefacts')
          .statusCode).toBe(200);
        const id = d.json().artefact_id;
        expectContract(await post(`/v1/artefacts/${id}/parts/1/url`, {}, deviceToken, false), 'POST', '/v1/artefacts/{id}/parts/{n}/url');
        t.fakes.objectStore.put(`captures/${SITE_A}/${scanId}/${step}/1/${kind}`, sha(`${step}-${kind}`));
        expectContract(await post(`/v1/artefacts/${id}/complete`, {}, deviceToken), 'POST', '/v1/artefacts/{id}/complete');
      }
    }
    expect((await pool.query('SELECT status::text AS s FROM scans WHERE id = $1', [scanId])).rows[0].s).toBe('quality_pending');
  });

  it('feature extraction (system agent)', async () => {
    await pool.query(`UPDATE scans SET status = 'quality_passed' WHERE id = $1`, [scanId]);
    expectContract(await post(`/v1/scans/${scanId}/features/extract`, {}, await tokenFor('system_agent')),
      'POST', '/v1/scans/{id}/features/extract');
  });

  it('review challenge, review, experimental view', async () => {
    for (const s of ['feature_pending', 'feature_complete', 'review_pending']) {
      await pool.query('UPDATE scans SET status = $2::scan_status WHERE id = $1', [scanId, s]);
    }
    await pool.query(
      `INSERT INTO site_protocol_flags(site_id,flag,enabled,changed_by) VALUES ($1,'show_experimental_at_bedside',true,'ct')`,
      [SITE_A],
    );
    await pool.query(
      `INSERT INTO features(scan_id,domain,name,value,pipeline_version,feature_availability_timestamp)
       VALUES ($1,'rppg_face','heart_rate',88.4,'v1',now())`,
      [scanId],
    );
    const ex = expectContract(await get(`/v1/scans/${scanId}/experimental`), 'GET', '/v1/scans/{id}/experimental');
    expect(ex.json().items).toHaveLength(1);
    const ch = expectContract(await post(`/v1/scans/${scanId}/review-challenge`, { action: 'confirm' }, await clinician(), false),
      'POST', '/v1/scans/{id}/review-challenge');
    expectContract(await post(`/v1/scans/${scanId}/review`, {
      challenge_id: ch.json().challenge_id, action: 'confirm', webauthn_assertion: { id: 'cred-1' },
    }, await clinician()), 'POST', '/v1/scans/{id}/review');
  });

  it('every documented route and success status was validated', () => {
    expect([...contractCovered].sort()).toEqual(allDocumentedSuccesses().sort());
  });
});
