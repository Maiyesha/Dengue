// Migration 0010: the `device` role may SELECT scan_step_attempts of its own site's scans (read-only).
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type pg from 'pg';
import { getTestPool, asRole } from './pg';
import { seedFixtures, clearFixtures, SITE_A, SITE_B, SCAN_A, SCAN_B } from './fixtures';

const pool = getTestPool();
const DEVICE = '00000000-0000-4000-c000-00000000010a';

beforeAll(async () => {
  await seedFixtures(pool);
  await pool.query(
    `INSERT INTO scan_step_attempts(scan_id, step, attempt, device_verdict)
     VALUES ($1,'neutral_face',1,'ACCEPT'), ($2,'neutral_face',1,'ACCEPT') ON CONFLICT DO NOTHING`,
    [SCAN_A, SCAN_B],
  );
});
afterAll(async () => {
  await pool.query('DELETE FROM scan_step_attempts WHERE scan_id = ANY($1)', [[SCAN_A, SCAN_B]]);
  await clearFixtures(pool);
  await pool.end();
});

const asDevice = <T>(fn: (c: pg.PoolClient) => Promise<T>, siteId?: string) =>
  asRole(pool, { userId: DEVICE, roles: ['device'], siteId }, fn);

describe('device role: scan_step_attempts', () => {
  it('sees attempts of its own site scans only', async () => {
    await asDevice(async (c) => {
      const r = await c.query('SELECT scan_id FROM scan_step_attempts WHERE scan_id = ANY($1)', [[SCAN_A, SCAN_B]]);
      expect(r.rows.map((x) => x.scan_id)).toEqual([SCAN_A]);
    }, SITE_A);
    await asDevice(async (c) => {
      const r = await c.query('SELECT scan_id FROM scan_step_attempts WHERE scan_id = ANY($1)', [[SCAN_A, SCAN_B]]);
      expect(r.rows.map((x) => x.scan_id)).toEqual([SCAN_B]);
    }, SITE_B);
  });

  it('no site → no rows', async () => {
    await asDevice(async (c) => {
      expect((await c.query('SELECT count(*)::int n FROM scan_step_attempts')).rows[0].n).toBe(0);
    });
  });

  it('cannot insert attempts, even for its own site', async () => {
    await asDevice(async (c) => {
      await expect(
        c.query(`INSERT INTO scan_step_attempts(scan_id, step, attempt, device_verdict) VALUES ($1,'neutral_face',2,'ACCEPT')`, [SCAN_A]),
      ).rejects.toThrow(/row-level security/);
    }, SITE_A);
  });
});
