// Migration 0012: device_challenges + the narrow devices privileges for the system_agent actor.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type pg from 'pg';
import { getTestPool, asRole } from './pg';
import { seedFixtures, clearFixtures, userFor, SITE_A, SITE_B, type Role } from './fixtures';

const pool = getTestPool();
const DEV_A = '00000000-0000-4000-c000-0000000012a1';
const DEV_A2 = '00000000-0000-4000-c000-0000000012a2';
const HASH = Buffer.alloc(32, 7);

beforeAll(async () => {
  await seedFixtures(pool);
});
afterAll(async () => {
  await clearFixtures(pool);
  await pool.end();
});

const asSuper = async (c: pg.PoolClient, sql: string, params: unknown[] = []) => {
  await c.query('RESET ROLE');
  const r = await c.query(sql, params);
  await c.query('SET LOCAL ROLE app_api');
  return r;
};
const seed = async (c: pg.PoolClient) => {
  await asSuper(c, `INSERT INTO wards(id,site_id) VALUES ('m12-wa',$1),('m12-wb',$2)`, [SITE_A, SITE_B]);
  await asSuper(c, `INSERT INTO devices(id,site_id,ward_id,app_attest_key_id,attest_public_key,push_token)
                    VALUES ($1,$3,'m12-wa','m12-k1','\\x01','tok-1'),($2,$3,'m12-wa','m12-k2','\\x02',NULL)`,
    [DEV_A, DEV_A2, SITE_A]);
};
/** Expects `sql` to fail with `code`, inside a savepoint so the transaction stays usable. */
const fails = async (c: pg.PoolClient, sql: string, params: unknown[], code: string) => {
  await c.query('SAVEPOINT f');
  await expect(c.query(sql, params)).rejects.toMatchObject({ code });
  await c.query('ROLLBACK TO SAVEPOINT f');
};
const as = <T>(role: Role, siteId: string | undefined, fn: (c: pg.PoolClient) => Promise<T>) =>
  asRole(pool, { userId: userFor(role), roles: [role], siteId }, fn);
const asSystem = <T>(siteId: string, fn: (c: pg.PoolClient) => Promise<T>) =>
  asRole(pool, { userId: 'sys', roles: ['system_agent'], siteId }, fn);

describe('device_challenges', () => {
  it('system_agent may insert/select/delete only on its own site', async () => {
    await asSystem(SITE_A, async (c) => {
      await c.query(`INSERT INTO device_challenges(challenge_hash, issued_to, site_id) VALUES ($1,'u',$2)`, [HASH, SITE_A]);
      expect((await c.query('SELECT 1 FROM device_challenges WHERE challenge_hash=$1', [HASH])).rowCount).toBe(1);
      await fails(c, `INSERT INTO device_challenges(challenge_hash, issued_to, site_id) VALUES ($1,'u',$2)`, [Buffer.alloc(32, 8), SITE_B], '42501');
      expect((await c.query('DELETE FROM device_challenges WHERE challenge_hash=$1', [HASH])).rowCount).toBe(1);
    });
    await asSystem(SITE_B, async (c) => {
      await asSuper(c, `INSERT INTO device_challenges(challenge_hash, issued_to, site_id) VALUES ($1,'u',$2)`, [HASH, SITE_A]);
      expect((await c.query('SELECT 1 FROM device_challenges')).rowCount).toBe(0);
      expect((await c.query('DELETE FROM device_challenges WHERE challenge_hash=$1', [HASH])).rowCount).toBe(0);
    });
  });

  it('site roles (admin, clinician) cannot see or write challenges directly', async () => {
    for (const role of ['admin', 'clinician'] as Role[]) {
      await as(role, SITE_A, async (c) => {
        await asSuper(c, `INSERT INTO device_challenges(challenge_hash, issued_to, site_id) VALUES ($1,'u',$2)`, [HASH, SITE_A]);
        expect((await c.query('SELECT 1 FROM device_challenges')).rowCount).toBe(0);
        await fails(c, `INSERT INTO device_challenges(challenge_hash, issued_to, site_id) VALUES ($1,'u',$2)`, [Buffer.alloc(32, 9), SITE_A], '42501');
      });
    }
  });

  it('challenge_hash must be 32 bytes', async () => {
    await asSystem(SITE_A, async (c) => {
      await fails(c, `INSERT INTO device_challenges(challenge_hash, issued_to, site_id) VALUES ('\\x01','u',$1)`, [SITE_A], '23514');
    });
  });
});

describe('devices writes', () => {
  it('system_agent inserts own-site devices only; site roles cannot insert', async () => {
    await asSystem(SITE_A, async (c) => {
      await seed(c);
      await c.query(`INSERT INTO devices(site_id,ward_id,app_attest_key_id,attest_public_key) VALUES ($1,'m12-wa','m12-k3','\\x03')`, [SITE_A]);
      await fails(c, `INSERT INTO devices(site_id,ward_id,app_attest_key_id) VALUES ($1,'m12-wb','m12-k4')`, [SITE_B], '42501');
    });
    await as('admin', SITE_A, async (c) => {
      await seed(c);
      await fails(c, `INSERT INTO devices(site_id,ward_id,app_attest_key_id) VALUES ($1,'m12-wa','m12-k5')`, [SITE_A], '42501');
    });
  });

  it('system_agent updates counter/push_token/status on its own site only; site roles update nothing', async () => {
    await asSystem(SITE_B, async (c) => {
      await seed(c);
      expect((await c.query(`UPDATE devices SET assertion_counter = 9 WHERE id = $1`, [DEV_A])).rowCount).toBe(0);
    });
    for (const role of ['admin', 'clinician', 'nurse_operator'] as Role[]) {
      await as(role, SITE_A, async (c) => {
        await seed(c);
        expect((await c.query(`UPDATE devices SET status = 'revoked' WHERE id = $1`, [DEV_A])).rowCount).toBe(0);
      });
    }
    await asSystem(SITE_A, async (c) => {
      await seed(c);
      expect((await c.query(`UPDATE devices SET assertion_counter = 9, push_token = 'p' WHERE id = $1`, [DEV_A])).rowCount).toBe(1);
      // identity columns are not UPDATE-granted
      await fails(c, `UPDATE devices SET attest_public_key = '\\x09' WHERE id = $1`, [DEV_A], '42501');
      await fails(c, `UPDATE devices SET site_id = $2 WHERE id = $1`, [DEV_A, SITE_B], '42501');
      // push_token stays unreadable even for system_agent
      await fails(c, `SELECT push_token FROM devices WHERE id = $1`, [DEV_A], '42501');
    });
  });
});

describe('device_attest_public_key()', () => {
  it('returns the key only to system_agent on the device site', async () => {
    const key = (c: pg.PoolClient) =>
      c.query<{ k: Buffer | null }>('SELECT device_attest_public_key($1) AS k', [DEV_A]).then((r) => r.rows[0].k);
    await asSystem(SITE_A, async (c) => {
      await seed(c);
      expect(await key(c)).toEqual(Buffer.from([1]));
    });
    await asSystem(SITE_B, async (c) => {
      await seed(c);
      expect(await key(c)).toBeNull();
    });
    for (const role of ['admin', 'clinician', 'regulatory_reviewer'] as Role[]) {
      await as(role, SITE_A, async (c) => {
        await seed(c);
        expect(await key(c)).toBeNull();
      });
    }
  });
});

describe('device role on devices', () => {
  it('a device reads only its own row, and only with matching site', async () => {
    await asRole(pool, { userId: DEV_A, roles: ['device'], siteId: SITE_A }, async (c) => {
      await seed(c);
      expect((await c.query('SELECT id FROM devices WHERE id IN ($1,$2)', [DEV_A, DEV_A2])).rows).toEqual([{ id: DEV_A }]);
      expect((await c.query(`UPDATE devices SET status='active' WHERE id = $1`, [DEV_A])).rowCount).toBe(0);
    });
    await asRole(pool, { userId: DEV_A, roles: ['device'], siteId: SITE_B }, async (c) => {
      await seed(c);
      expect((await c.query('SELECT id FROM devices WHERE id = $1', [DEV_A])).rowCount).toBe(0);
    });
  });
});
