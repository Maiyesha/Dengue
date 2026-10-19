import { describe, it, expect, afterAll } from 'vitest';
import { getTestPool, asRole } from './pg';

const pool = getTestPool();
afterAll(async () => { await pool.end(); });

async function tx<T>(fn: (c: import('pg').PoolClient) => Promise<T>): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    return await fn(c);
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}

async function seed(c: import('pg').PoolClient, code = 'DS-KL-00001') {
  await c.query(`INSERT INTO sites(id,name) VALUES ('KL','Kuala Lumpur') ON CONFLICT DO NOTHING`);
  const r = await c.query(
    `INSERT INTO patients(participant_code,pseudonym_id,site_id) VALUES ($1,$2,'KL') RETURNING id`,
    [code, 'ps-' + code],
  );
  return r.rows[0].id as string;
}

describe('patients / vault / consent', () => {
  it("participant_code rejects 'NMRR-2026-00123'", async () => {
    await tx(async (c) => {
      await c.query(`INSERT INTO sites(id,name) VALUES ('KL','Kuala Lumpur')`);
      await expect(
        c.query(`INSERT INTO patients(participant_code,pseudonym_id,site_id) VALUES ('NMRR-2026-00123','p1','KL')`),
      ).rejects.toMatchObject({ code: '23514' });
    });
  });

  it('app_api cannot select vault.patient_identifiers', async () => {
    await expect(
      asRole(pool, { userId: 'u1', roles: ['admin'] }, (c) => c.query('SELECT * FROM vault.patient_identifiers')),
    ).rejects.toMatchObject({ code: '42501' });
  });

  it('consent status shows superseded', async () => {
    await tx(async (c) => {
      const pid = await seed(c);
      await c.query(`INSERT INTO consent_versions(version,is_current) VALUES ('v1',false),('v2',true)`);
      await c.query(
        `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at) VALUES ($1,'v1',true,now())`,
        [pid],
      );
      const r = await c.query(`SELECT * FROM patient_consent_status WHERE patient_id=$1`, [pid]);
      expect(r.rows[0]).toMatchObject({ consent_version: 'v1', current_version: 'v2', withdrawn: false, primary_research: true });
    });
  });

  it('withdrawn consent sets withdrawn=true', async () => {
    await tx(async (c) => {
      const pid = await seed(c);
      await c.query(`INSERT INTO consent_versions(version,is_current) VALUES ('v1',true)`);
      await c.query(
        `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at,withdrawn_at) VALUES ($1,'v1',true,now(),now())`,
        [pid],
      );
      const r = await c.query(`SELECT withdrawn FROM patient_consent_status WHERE patient_id=$1`, [pid]);
      expect(r.rows[0].withdrawn).toBe(true);
    });
  });
});
