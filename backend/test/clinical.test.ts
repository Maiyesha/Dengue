import { describe, it, expect, afterAll } from 'vitest';
import { getTestPool } from './pg';

const pool = getTestPool();
afterAll(async () => { await pool.end(); });

type C = import('pg').PoolClient;
async function tx<T>(fn: (c: C) => Promise<T>): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    return await fn(c);
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}

async function seed(c: C) {
  await c.query(`INSERT INTO sites(id,name) VALUES ('KL','Kuala Lumpur') ON CONFLICT DO NOTHING`);
  const p = await c.query(
    `INSERT INTO patients(participant_code,pseudonym_id,site_id) VALUES ('DS-KL-00001','ps-1','KL') RETURNING id`,
  );
  const s = await c.query(
    `INSERT INTO scans(client_session_id,patient_id,site_id,captured_at,protocol_version)
     VALUES ('11111111-1111-1111-1111-111111111111',$1,'KL',now(),'1.0') RETURNING id`,
    [p.rows[0].id],
  );
  return { patientId: p.rows[0].id as string, scanId: s.rows[0].id as string };
}

async function obs(c: C, patientId: string, vital: string, value: number) {
  const r = await c.query(
    `INSERT INTO clinical_observations(patient_id,observer_user_id,measured_at,vital,value,source_device_type)
     VALUES ($1,'u1',now(),$2,$3,'oximeter') RETURNING validity`,
    [patientId, vital, value],
  );
  return r.rows[0].validity as string;
}

describe('clinical observations', () => {
  it('spo2 120 stored with validity INVALID', async () => {
    await tx(async (c) => {
      const { patientId } = await seed(c);
      expect(await obs(c, patientId, 'spo2', 120)).toBe('INVALID');
      const n = await c.query(`SELECT count(*)::int n FROM clinical_observations`);
      expect(n.rows[0].n).toBe(1);
    });
  });
  it('hr 88 stored VALID', async () => {
    await tx(async (c) => {
      const { patientId } = await seed(c);
      expect(await obs(c, patientId, 'hr', 88)).toBe('VALID');
    });
  });
  it('range bounds are inclusive', async () => {
    await tx(async (c) => {
      const { patientId } = await seed(c);
      expect(await obs(c, patientId, 'hr', 30)).toBe('VALID');
      expect(await obs(c, patientId, 'hr', 220)).toBe('VALID');
      expect(await obs(c, patientId, 'hr', 29.9)).toBe('INVALID');
      expect(await obs(c, patientId, 'crt_s', 10)).toBe('VALID');
      expect(await obs(c, patientId, 'temp_c', 42.1)).toBe('INVALID');
    });
  });
});

describe('features', () => {
  const ins = (c: C, scanId: string, tier: string, ts: string | null) =>
    c.query(
      `INSERT INTO features(scan_id,domain,name,value,pipeline_version,feature_availability_timestamp,tier)
       VALUES ($1,'facial','x',1,'v1',$2,$3)`,
      [scanId, ts, tier],
    );
  it('feature without availability timestamp rejected', async () => {
    await tx(async (c) => {
      const { scanId } = await seed(c);
      await expect(ins(c, scanId, 'experimental', null)).rejects.toMatchObject({ code: '23502' });
    });
  });
  it("feature tier 'validated' rejected", async () => {
    await tx(async (c) => {
      const { scanId } = await seed(c);
      await expect(ins(c, scanId, 'validated', new Date().toISOString())).rejects.toMatchObject({ code: '23514' });
    });
  });
  it('experimental feature accepted', async () => {
    await tx(async (c) => {
      const { scanId } = await seed(c);
      await ins(c, scanId, 'experimental', new Date().toISOString());
    });
  });
});

describe('sqi_checks / labs / reviews', () => {
  it('sqi_checks accepts fingertip_coverage', async () => {
    await tx(async (c) => {
      const { scanId } = await seed(c);
      await c.query(
        `INSERT INTO sqi_checks(scan_id,step,attempt,check_id,source,passed) VALUES ($1,'fingertip_ppg',1,'fingertip_coverage','device',true)`,
        [scanId],
      );
    });
  });
  it('lab_values accepts platelet_count', async () => {
    await tx(async (c) => {
      const { patientId } = await seed(c);
      await c.query(
        `INSERT INTO lab_values(patient_id,test,value,unit,collected_at,methodology) VALUES ($1,'platelet_count',150,'10^9/L',now(),'analyser')`,
        [patientId],
      );
    });
  });
  it('scan_reviews requires 64-char hash and valid action', async () => {
    await tx(async (c) => {
      const { scanId } = await seed(c);
      await c.query(
        `INSERT INTO scan_reviews(scan_id,reviewer_user_id,action,webauthn_assertion_hash) VALUES ($1,'u1','confirm',repeat('a',64))`,
        [scanId],
      );
      await expect(
        c.query(`INSERT INTO scan_reviews(scan_id,reviewer_user_id,action,webauthn_assertion_hash) VALUES ($1,'u1','bogus',repeat('a',64))`, [scanId]),
      ).rejects.toMatchObject({ code: '23514' });
    });
  });
});
