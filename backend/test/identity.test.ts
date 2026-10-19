import { describe, it, expect } from 'vitest';
import { getTestPool, asRole } from './pg';

const pool = getTestPool();

describe('identity schema', () => {
  it('app_roles() returns {} when unset', async () => {
    await asRole(pool, { userId: 'u1', roles: [] }, async (c) => {
      const r = await c.query('SELECT app_roles() AS r');
      expect(r.rows[0].r).toEqual([]);
    });
    const c = await pool.connect();
    try {
      const r = await c.query('SELECT app_roles() AS r');
      expect(r.rows[0].r).toEqual([]);
    } finally {
      c.release();
    }
  });

  it("app_roles() parses 'clinician,admin'", async () => {
    await asRole(pool, { userId: 'u1', roles: ['clinician', 'admin'] }, async (c) => {
      const r = await c.query("SELECT app_roles() AS r, app_has_role('admin') AS a, app_has_role('nurse_operator') AS n");
      expect(r.rows[0].r).toEqual(['clinician', 'admin']);
      expect(r.rows[0].a).toBe(true);
      expect(r.rows[0].n).toBe(false);
    });
  });

  it("devices.status rejects 'lost'", async () => {
    const c = await pool.connect();
    try {
      await c.query('BEGIN');
      await c.query("INSERT INTO sites(id,name) VALUES ('s1','Site 1')");
      await c.query("INSERT INTO wards(id,site_id) VALUES ('w1','s1')");
      await expect(
        c.query("INSERT INTO devices(id,site_id,ward_id,status) VALUES (uuid_generate_v4(),'s1','w1','lost')"),
      ).rejects.toThrow(/check constraint/i);
    } finally {
      await c.query('ROLLBACK');
      c.release();
    }
  });

  it("app_users.role rejects 'nurse'", async () => {
    const c = await pool.connect();
    try {
      await c.query('BEGIN');
      await expect(
        c.query("INSERT INTO app_users(id,idp_subject,role) VALUES ('u9','sub9','nurse')"),
      ).rejects.toThrow(/invalid input value for enum/i);
    } finally {
      await c.query('ROLLBACK');
      c.release();
    }
  });
});
