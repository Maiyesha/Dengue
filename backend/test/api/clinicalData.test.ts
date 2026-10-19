import { randomUUID } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { getTestPool } from '../pg';
import { seedFixtures, clearFixtures, SITE_A, PATIENT_A, PATIENT_B } from '../fixtures';
import { buildTestApp, tokenFor, bearer } from './helpers';

const pool = getTestPool();
let app: FastifyInstance;
const obsIds: string[] = [];
const labIds: string[] = [];

const ob = (o: Record<string, unknown> = {}) => {
  const observation_id = randomUUID();
  obsIds.push(observation_id);
  return {
    observation_id,
    vital: 'hr',
    value: 80,
    unit: '/min',
    source_device_type: 'pulse_oximeter',
    measured_at: new Date().toISOString(),
    ...o,
  };
};

const post = async (patient: string, body: unknown, o: { token?: string; key?: string } = {}) =>
  app.inject({
    method: 'POST',
    url: `/v1/patients/${patient}/clinical-data`,
    headers: { ...bearer(o.token ?? (await tokenFor('nurse_operator', SITE_A))), 'idempotency-key': o.key ?? randomUUID() },
    payload: body as object,
  });

beforeAll(async () => {
  await seedFixtures(pool);
  app = (await buildTestApp()).app;
});
afterAll(async () => {
  await pool.query('DELETE FROM clinical_observations WHERE observation_id = ANY($1)', [obsIds]);
  await pool.query('DELETE FROM lab_values WHERE id = ANY($1)', [labIds]);
  await clearFixtures(pool);
  await app.close();
});

describe('clinical data', () => {
  it('stores vitals with source device', async () => {
    const o = ob();
    const r = await post(PATIENT_A, { observations: [o] });
    expect(r.statusCode).toBe(201);
    expect(r.json()).toEqual({ accepted: 1, duplicates: 0, invalid: [] });
    const row = (await pool.query('SELECT * FROM clinical_observations WHERE observation_id=$1', [o.observation_id])).rows[0];
    expect(row.source_device_type).toBe('pulse_oximeter');
    expect(row.observer_user_id).toBe('rls-nurse_operator');
    expect(row.validity).toBe('VALID');
  });

  it('stores labs and counts resends as duplicates', async () => {
    const id = randomUUID();
    labIds.push(id);
    const lab = { id, test: 'platelet_count', value: 120, unit: '10^9/L', collected_at: new Date().toISOString(), methodology: 'analyser' };
    expect((await post(PATIENT_A, { observations: [], labs: [lab] })).json()).toEqual({ accepted: 1, duplicates: 0, invalid: [] });
    expect((await post(PATIENT_A, { observations: [], labs: [lab] })).json()).toEqual({ accepted: 0, duplicates: 1, invalid: [] });
  });

  it('resend same observation_id counts as duplicate', async () => {
    const o = ob();
    await post(PATIENT_A, { observations: [o] });
    const r = await post(PATIENT_A, { observations: [o] });
    expect(r.statusCode).toBe(201);
    expect(r.json()).toEqual({ accepted: 0, duplicates: 1, invalid: [] });
    const n = await pool.query('SELECT count(*)::int AS n FROM clinical_observations WHERE observation_id=$1', [o.observation_id]);
    expect(n.rows[0].n).toBe(1);
  });

  it('spo2 120 accepted and listed in invalid', async () => {
    const o = ob({ vital: 'spo2', value: 120, unit: '%' });
    const r = await post(PATIENT_A, { observations: [o] });
    expect(r.json()).toEqual({ accepted: 1, duplicates: 0, invalid: [o.observation_id] });
    const row = (await pool.query('SELECT validity FROM clinical_observations WHERE observation_id=$1', [o.observation_id])).rows[0];
    expect(row.validity).toBe('INVALID');
  });

  it('missing source_device_type → 400', async () => {
    const { source_device_type: _s, ...o } = ob();
    const r = await post(PATIENT_A, { observations: [o] });
    expect(r.statusCode).toBe(400);
    expect(r.json().error.code).toBe('DS_VALIDATION_001');
  });

  it('rejects far-future measured_at, unknown fields, non-ISO dates', async () => {
    const fut = ob({ measured_at: new Date(Date.now() + 10 * 60_000).toISOString() });
    const f = await post(PATIENT_A, { observations: [fut] });
    expect(f.statusCode).toBe(400);
    expect(f.json().error.code).toBe('DS_VALIDATION_001');
    expect((await post(PATIENT_A, { observations: [ob({ extra: 1 })] })).statusCode).toBe(400);
    expect((await post(PATIENT_A, { observations: [ob({ measured_at: 'yesterday' })] })).statusCode).toBe(400);
  });

  it('cross-site patient is 404; wrong role 403', async () => {
    const r = await post(PATIENT_B, { observations: [ob()] });
    expect(r.statusCode).toBe(404);
    expect(r.json().error.code).toBe('DS_NOT_FOUND');
    const t = await tokenFor('researcher', SITE_A);
    expect((await post(PATIENT_A, { observations: [ob()] }, { token: t })).statusCode).toBe(403);
  });

  it('observation_id belonging to another patient is 409 DS_CLINICAL_001', async () => {
    const o = ob();
    await pool.query(
      `INSERT INTO clinical_observations(observation_id,patient_id,observer_user_id,measured_at,vital,value,source_device_type)
       VALUES ($1,$2,'x',now(),'hr',70,'d')`,
      [o.observation_id, PATIENT_B],
    );
    const r = await post(PATIENT_A, { observations: [o] });
    expect(r.statusCode).toBe(409);
    expect(r.json().error.code).toBe('DS_CLINICAL_001');
  });

  const VITAL_UNITS: Record<string, string> = {
    hr: '/min', spo2: '%', sbp: 'mmHg', dbp: 'mmHg', temp_c: '°C', rr: '/min', crt_s: 's',
  };
  const LAB_UNITS: Record<string, string> = {
    haemoglobin: 'g/dL', haematocrit: '%', wbc_count: '10^9/L', platelet_count: '10^9/L',
  };
  const lab = (test: string, unit: string) => {
    const id = randomUUID();
    labIds.push(id);
    return { id, test, value: 10, unit, collected_at: new Date().toISOString(), methodology: 'analyser' };
  };

  it('accepts every vital and lab in its fixed unit', async () => {
    const observations = Object.entries(VITAL_UNITS).map(([vital, unit]) => ob({ vital, unit, value: 1 }));
    const labs = Object.entries(LAB_UNITS).map(([t, u]) => lab(t, u));
    const r = await post(PATIENT_A, { observations, labs });
    expect(r.statusCode).toBe(201);
    expect(r.json().accepted).toBe(observations.length + labs.length);
  });

  it('a mismatched unit -> 400 DS_VALIDATION_001 (vitals and labs)', async () => {
    const wrong: Array<[string, string]> = [
      ['hr', 'bpm'], ['spo2', 'percent'], ['sbp', 'kPa'], ['dbp', 'mmhg'], ['temp_c', 'F'], ['rr', 'bpm'], ['crt_s', 'ms'],
    ];
    for (const [vital, unit] of wrong) {
      const r = await post(PATIENT_A, { observations: [ob({ vital, unit })] });
      expect(r.statusCode, `${vital} ${unit}`).toBe(400);
      expect(r.json().error.code).toBe('DS_VALIDATION_001');
    }
    for (const [t, u] of [['haemoglobin', 'g/L'], ['haematocrit', 'L/L'], ['wbc_count', '/uL'], ['platelet_count', '10^3/uL']]) {
      const r = await post(PATIENT_A, { observations: [], labs: [lab(t, u)] });
      expect(r.statusCode, `${t} ${u}`).toBe(400);
      expect(r.json().error.code).toBe('DS_VALIDATION_001');
    }
  });

  it('writes a clinical_data:create audit row', async () => {
    const q = `SELECT count(*)::int AS n FROM clinical_audit_log WHERE outcome='clinical_data:create'`;
    const before = (await pool.query(q)).rows[0].n;
    await post(PATIENT_A, { observations: [ob()] });
    expect((await pool.query(q)).rows[0].n).toBe(before + 1);
  });
});
