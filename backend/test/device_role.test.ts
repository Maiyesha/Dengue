// Migration 0008: the `device` app role (own-site scans SELECT/UPDATE, artefacts SELECT/INSERT/UPDATE,
// capture_pending -> quality_pending authority) and quality_failed -> acquisition_failure for site roles.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type pg from 'pg';
import { getTestPool, asRole } from './pg';
import { seedFixtures, clearFixtures, userFor, SITE_A, SITE_B, SCAN_A, SCAN_B, type Role } from './fixtures';

const pool = getTestPool();
const DEVICE = '00000000-0000-4000-c000-00000000000a';

beforeAll(async () => { await seedFixtures(pool); });
afterAll(async () => {
  await clearFixtures(pool);
  await pool.end();
});

const asDevice = <T>(fn: (c: pg.PoolClient) => Promise<T>, siteId: string | null = SITE_A) =>
  asRole(pool, { userId: DEVICE, roles: ['device'], siteId: siteId ?? undefined }, fn);
const as = <T>(role: Role, fn: (c: pg.PoolClient) => Promise<T>, siteId?: string) =>
  asRole(pool, { userId: userFor(role), roles: [role], siteId }, fn);

/** Superuser statement inside the (rolled-back) asRole transaction. */
const asSuper = async (c: pg.PoolClient, sql: string, params: unknown[] = []) => {
  await c.query('RESET ROLE');
  const r = await c.query(sql, params);
  await c.query('SET LOCAL ROLE app_api');
  return r;
};
const setStatus = (c: pg.PoolClient, id: string, statuses: string[]) =>
  statuses.reduce<Promise<unknown>>((p, s) =>
    p.then(() => asSuper(c, 'UPDATE scans SET status=$2::scan_status WHERE id=$1', [id, s])), Promise.resolve());
const statusOf = async (c: pg.PoolClient, id: string) =>
  (await asSuper(c, 'SELECT status FROM scans WHERE id=$1', [id])).rows[0].status as string;

const insArtefact = (c: pg.PoolClient, scanId: string, key: string) =>
  c.query(`INSERT INTO artefacts(scan_id, step, attempt, kind, sha256, object_key)
           VALUES ($1,'neutral_face',1,'video',repeat('a',64),$2)`, [scanId, key]);

describe('device role: scans', () => {
  it('sees only its own site scans; no site → none', async () => {
    await asDevice(async (c) => {
      const ids = (await c.query('SELECT id FROM scans WHERE id = ANY($1)', [[SCAN_A, SCAN_B]])).rows.map((r) => r.id);
      expect(ids).toEqual([SCAN_A]);
    });
    await asDevice(async (c) => {
      expect((await c.query('SELECT count(*)::int n FROM scans')).rows[0].n).toBe(0);
    }, null);
  });

  it('may move its own site scan capture_pending -> quality_pending', async () => {
    await asDevice(async (c) => {
      const r = await c.query(`UPDATE scans SET status='quality_pending' WHERE id=$1`, [SCAN_A]);
      expect(r.rowCount).toBe(1);
      expect(await statusOf(c, SCAN_A)).toBe('quality_pending');
    });
  });

  it('cannot update another site scan (0 rows)', async () => {
    await asDevice(async (c) => {
      const r = await c.query(`UPDATE scans SET status='quality_pending' WHERE id=$1`, [SCAN_B]);
      expect(r.rowCount).toBe(0);
    });
  });

  it('has no other transition authority (acquisition_failure, revoked, quality verdicts)', async () => {
    for (const [from, to] of [
      [[], 'acquisition_failure'],
      [[], 'revoked'],
      [['quality_pending'], 'quality_passed'],
      [['quality_pending', 'quality_failed'], 'capture_pending'],
      [['quality_pending', 'quality_failed'], 'acquisition_failure'],
    ] as Array<[string[], string]>) {
      await asDevice(async (c) => {
        await setStatus(c, SCAN_A, from);
        await expect(c.query('UPDATE scans SET status=$2::scan_status WHERE id=$1', [SCAN_A, to]))
          .rejects.toThrow(/DS_STATE_003/);
      });
    }
  });

  it('cannot insert scans or read patients', async () => {
    await asDevice(async (c) => {
      await expect(c.query(`INSERT INTO scans(client_session_id, site_id, captured_at, protocol_version)
                            VALUES (gen_random_uuid(), $1, now(), 'p1')`, [SITE_A])).rejects.toMatchObject({ code: '42501' });
    });
    await asDevice(async (c) => {
      expect((await c.query('SELECT count(*)::int n FROM patients')).rows[0].n).toBe(0);
    });
  });

  it('cannot change scan site/patient (immutable)', async () => {
    await asDevice(async (c) => {
      await expect(c.query('UPDATE scans SET site_id=$2 WHERE id=$1', [SCAN_A, SITE_B])).rejects.toThrow();
    });
  });
});

describe('device role: artefacts', () => {
  it('insert/select/update artefacts of an own-site scan', async () => {
    await asDevice(async (c) => {
      await insArtefact(c, SCAN_A, 'dev-own-1');
      const sel = await c.query(`SELECT id FROM artefacts WHERE object_key='dev-own-1'`);
      expect(sel.rowCount).toBe(1);
      const up = await c.query(`UPDATE artefacts SET status='uploading' WHERE object_key='dev-own-1'`);
      expect(up.rowCount).toBe(1);
    });
  });

  it('cannot insert an artefact for another site scan', async () => {
    await asDevice(async (c) => {
      await expect(insArtefact(c, SCAN_B, 'dev-other-1')).rejects.toMatchObject({ code: '42501' });
    });
  });

  it('cannot see or update another site artefacts', async () => {
    await asDevice(async (c) => {
      await asSuper(c, `INSERT INTO artefacts(scan_id, step, attempt, kind, sha256, object_key)
                        VALUES ($1,'neutral_face',1,'video',repeat('b',64),'dev-other-2')`, [SCAN_B]);
      expect((await c.query(`SELECT 1 FROM artefacts WHERE object_key='dev-other-2'`)).rowCount).toBe(0);
      expect((await c.query(`UPDATE artefacts SET status='rejected' WHERE object_key='dev-other-2'`)).rowCount).toBe(0);
    });
  });

  it('device with no site cannot insert artefacts', async () => {
    await asDevice(async (c) => {
      await expect(insArtefact(c, SCAN_A, 'dev-nosite')).rejects.toMatchObject({ code: '42501' });
    }, null);
  });
});

describe('quality_failed -> acquisition_failure authority', () => {
  for (const role of ['nurse_operator', 'clinician'] as Role[]) {
    it(`${role} may perform it on an own-site scan`, async () => {
      await as(role, async (c) => {
        await setStatus(c, SCAN_A, ['quality_pending', 'quality_failed']);
        const r = await c.query(`UPDATE scans SET status='acquisition_failure' WHERE id=$1`, [SCAN_A]);
        expect(r.rowCount).toBe(1);
        expect(await statusOf(c, SCAN_A)).toBe('acquisition_failure');
      }, SITE_A);
    });
  }

  it('system_agent may not', async () => {
    await as('system_agent', async (c) => {
      await setStatus(c, SCAN_A, ['quality_pending', 'quality_failed']);
      await expect(c.query(`UPDATE scans SET status='acquisition_failure' WHERE id=$1`, [SCAN_A]))
        .rejects.toThrow(/DS_STATE_003/);
    });
  });

  it('site roles keep capture_pending -> acquisition_failure', async () => {
    await as('nurse_operator', async (c) => {
      const r = await c.query(`UPDATE scans SET status='acquisition_failure' WHERE id=$1`, [SCAN_A]);
      expect(r.rowCount).toBe(1);
    }, SITE_A);
  });
});
