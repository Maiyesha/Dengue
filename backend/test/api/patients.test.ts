import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { getTestPool } from '../pg';
import { seedFixtures, clearFixtures, SITE_A, SITE_B, PATIENT_A, PATIENT_B, CONSENT_VERSION } from '../fixtures';
import { buildTestApp, tokenFor, deviceTokenFor, bearer } from './helpers';

const pool = getTestPool();
let app: FastifyInstance;

const WARD_1 = 'RLSA-W1';
const WARD_2 = 'RLSA-W2';
const PATIENT_W1 = '00000000-0000-4000-a000-0000000000c1';
const PATIENT_W2 = '00000000-0000-4000-a000-0000000000c2';
const FORBIDDEN_KEYS = ['name', 'nric', 'mrn', 'dob', 'date_of_birth'];

const get = async (url: string, role = 'nurse_operator', site: string | undefined = SITE_A) =>
  app.inject({ method: 'GET', url, headers: bearer(await tokenFor(role, site)) });

const allKeys = (v: unknown): string[] =>
  Array.isArray(v)
    ? v.flatMap(allKeys)
    : v && typeof v === 'object'
      ? Object.entries(v).flatMap(([k, x]) => [k, ...allKeys(x)])
      : [];

beforeAll(async () => {
  await seedFixtures(pool);
  ({ app } = await buildTestApp());
  await pool.query(`INSERT INTO wards(id, site_id) VALUES ($1,$3),($2,$3) ON CONFLICT DO NOTHING`, [WARD_1, WARD_2, SITE_A]);
  await pool.query(
    `INSERT INTO patients(id,participant_code,pseudonym_id,site_id,ward_id,bed_label,cohort)
     VALUES ($1,'DS-RLSA-00002','ps-rls-w1',$3,$4,'W1-02','dengue'),
            ($2,'DS-RLSA-00003','ps-rls-w2',$3,$5,'W2-01','dengue')
     ON CONFLICT DO NOTHING`,
    [PATIENT_W1, PATIENT_W2, SITE_A, WARD_1, WARD_2],
  );
  await pool.query(`UPDATE patients SET ward_id=$2, bed_label='A-01' WHERE id=$1`, [PATIENT_A, WARD_1]);
  await pool.query(
    `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at) VALUES ($1,$2,true,now())`,
    [PATIENT_W1, CONSENT_VERSION],
  );
});

afterAll(async () => {
  await app.close();
  await pool.query('DELETE FROM consents WHERE patient_id = ANY($1)', [[PATIENT_W1, PATIENT_W2]]);
  await pool.query('DELETE FROM patients WHERE id = ANY($1)', [[PATIENT_W1, PATIENT_W2]]);
  await pool.query('UPDATE patients SET ward_id=NULL WHERE id=$1', [PATIENT_A]);
  await pool.query('DELETE FROM wards WHERE id = ANY($1)', [[WARD_1, WARD_2]]);
  await pool.query(`DELETE FROM consent_versions WHERE version = 'rls-v0'`);
  await clearFixtures(pool);
  await pool.end();
});

describe('GET /v1/patients/lookup', () => {
  it('lookup returns no name/nric/mrn/dob keys', async () => {
    const r = await get('/v1/patients/lookup?participant_code=DS-RLSA-00001');
    expect(r.statusCode).toBe(200);
    const b = r.json();
    expect(Object.keys(b).sort()).toEqual(['bed_label', 'last_captured_at', 'participant_code', 'patient_id', 'ward_id']);
    expect(b).toMatchObject({ patient_id: PATIENT_A, participant_code: 'DS-RLSA-00001', bed_label: 'A-01', ward_id: WARD_1 });
    expect(typeof b.last_captured_at).toBe('string');
    for (const k of FORBIDDEN_KEYS) expect(allKeys(b)).not.toContain(k);
  });

  it('last_captured_at is null when the patient has no scans', async () => {
    const r = await get('/v1/patients/lookup?participant_code=DS-RLSA-00002', 'clinician');
    expect(r.statusCode).toBe(200);
    expect(r.json().last_captured_at).toBeNull();
  });

  it('lookup of site-B patient by site-A nurse → 404', async () => {
    const r = await get('/v1/patients/lookup?participant_code=DS-RLSB-00001');
    expect(r.statusCode).toBe(404);
    expect(r.json().error.code).toBe('DS_NOT_FOUND');
  });

  it('unknown code → 404; malformed → 400; missing → 400', async () => {
    expect((await get('/v1/patients/lookup?participant_code=DS-RLSA-99999')).json().error.code).toBe('DS_NOT_FOUND');
    const bad = await get('/v1/patients/lookup?participant_code=nope');
    expect(bad.statusCode).toBe(400);
    expect(bad.json().error.code).toBe('DS_VALIDATION_001');
    expect((await get('/v1/patients/lookup')).statusCode).toBe(400);
  });

  it('wrong role → 403, device → 403, no token → 401', async () => {
    expect((await get('/v1/patients/lookup?participant_code=DS-RLSA-00001', 'researcher', undefined)).statusCode).toBe(403);
    const d = await app.inject({
      method: 'GET',
      url: '/v1/patients/lookup?participant_code=DS-RLSA-00001',
      headers: bearer(await deviceTokenFor('00000000-0000-4000-c000-00000000000a', SITE_A)),
    });
    expect(d.statusCode).toBe(403);
    expect((await app.inject({ method: 'GET', url: '/v1/patients/lookup?participant_code=DS-RLSA-00001' })).statusCode).toBe(401);
  });

  it('is audited as data_access with the patient pseudonym', async () => {
    await get('/v1/patients/lookup?participant_code=DS-RLSA-00001');
    const a = await pool.query(
      `SELECT patient_pseudonym, resource_type, outcome FROM clinical_audit_log
        WHERE event_type='data_access' AND resource_id=$1 ORDER BY occurred_at DESC LIMIT 1`,
      [PATIENT_A],
    );
    expect(a.rows[0]).toEqual({ patient_pseudonym: 'ps-rls-a', resource_type: 'patient', outcome: 'success' });
  });
});

describe('GET /v1/wards/:wardId/roster', () => {
  it('roster only lists own ward', async () => {
    const r = await get(`/v1/wards/${WARD_1}/roster`);
    expect(r.statusCode).toBe(200);
    const b = r.json();
    const ids = b.items.map((i: { patient_id: string }) => i.patient_id);
    expect([...ids].sort()).toEqual([PATIENT_A, PATIENT_W1].sort());
    expect(ids).not.toContain(PATIENT_W2);
    expect(typeof b.generated_at).toBe('string');
    const w1 = b.items.find((i: { patient_id: string }) => i.patient_id === PATIENT_W1);
    expect(w1.consent).toMatchObject({ primary_research: true, consent_version: CONSENT_VERSION, withdrawn: false });
    for (const k of FORBIDDEN_KEYS) expect(allKeys(b)).not.toContain(k);
  });

  it('other site ward or unknown ward → 404', async () => {
    const b = await get(`/v1/wards/${WARD_1}/roster`, 'nurse_operator', SITE_B);
    expect(b.statusCode).toBe(404);
    expect(b.json().error.code).toBe('DS_NOT_FOUND');
    expect((await get('/v1/wards/NOPE/roster')).statusCode).toBe(404);
  });
});

describe('GET /v1/patients/:id/consent-status', () => {
  it('current consent', async () => {
    const r = await get(`/v1/patients/${PATIENT_A}/consent-status`);
    expect(r.statusCode).toBe(200);
    expect(r.json()).toMatchObject({
      primary_research: true,
      consent_version: CONSENT_VERSION,
      current_version: CONSENT_VERSION,
      withdrawn: false,
    });
    expect(typeof r.json().checked_at).toBe('string');
  });

  it('consent-status superseded shows differing versions', async () => {
    await pool.query(`INSERT INTO consent_versions(version,is_current) VALUES ('rls-v0', false) ON CONFLICT DO NOTHING`);
    await pool.query(
      `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at) VALUES ($1,'rls-v0',true,now())`,
      [PATIENT_W2],
    );
    const r = await get(`/v1/patients/${PATIENT_W2}/consent-status`);
    expect(r.statusCode).toBe(200);
    const b = r.json();
    expect(b.consent_version).toBe('rls-v0');
    expect(b.current_version).toBe(CONSENT_VERSION);
  });

  it('cross-site / unknown / bad id', async () => {
    const x = await get(`/v1/patients/${PATIENT_B}/consent-status`);
    expect(x.statusCode).toBe(404);
    expect(x.json().error.code).toBe('DS_NOT_FOUND');
    expect((await get('/v1/patients/00000000-0000-4000-a000-ffffffffffff/consent-status')).statusCode).toBe(404);
    expect((await get('/v1/patients/not-a-uuid/consent-status')).statusCode).toBe(400);
  });
});
