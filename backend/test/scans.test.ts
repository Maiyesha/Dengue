import { describe, it, expect, afterAll } from 'vitest';
import { getTestPool } from './pg';

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

async function seedScan(c: import('pg').PoolClient, sessionId = '11111111-1111-1111-1111-111111111111') {
  await c.query(`INSERT INTO sites(id,name) VALUES ('KL','Kuala Lumpur') ON CONFLICT DO NOTHING`);
  const p = await c.query(
    `INSERT INTO patients(participant_code,pseudonym_id,site_id) VALUES ('DS-KL-00001','ps-1','KL') RETURNING id`,
  );
  const s = await c.query(
    `INSERT INTO scans(client_session_id,patient_id,site_id,captured_at,protocol_version)
     VALUES ($1,$2,'KL',now(),'1.0') RETURNING id`,
    [sessionId, p.rows[0].id],
  );
  return s.rows[0].id as string;
}

describe('scans', () => {
  it('client_session_id is unique', async () => {
    await tx(async (c) => {
      await seedScan(c);
      await expect(
        c.query(`INSERT INTO scans(client_session_id,site_id,captured_at,protocol_version)
                 VALUES ('11111111-1111-1111-1111-111111111111','KL',now(),'1.0')`),
      ).rejects.toMatchObject({ code: '23505' });
    });
  });

  it('attempt 4 is rejected', async () => {
    await tx(async (c) => {
      const id = await seedScan(c);
      await expect(
        c.query(`INSERT INTO scan_step_attempts(scan_id,step,attempt,device_verdict) VALUES ($1,'positioning',4,'ACCEPT')`, [id]),
      ).rejects.toMatchObject({ code: '23514' });
    });
  });

  it('capture_pending→feature_pending raises DS_STATE_001', async () => {
    await tx(async (c) => {
      const id = await seedScan(c);
      await expect(
        c.query(`UPDATE scans SET status='feature_pending' WHERE id=$1`, [id]),
      ).rejects.toThrow(/DS_STATE_001/);
    });
  });

  it('review_pending→reviewed allowed', async () => {
    await tx(async (c) => {
      const id = await seedScan(c);
      for (const s of ['quality_pending', 'quality_passed', 'feature_pending', 'feature_complete', 'review_pending', 'reviewed']) {
        await c.query(`UPDATE scans SET status=$2 WHERE id=$1`, [id, s]);
      }
      const r = await c.query(`SELECT status FROM scans WHERE id=$1`, [id]);
      expect(r.rows[0].status).toBe('reviewed');
    });
  });
});
