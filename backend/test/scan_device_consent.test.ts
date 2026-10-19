// Migration 0013: scans.device_id guard for the `device` role (F1) and the SECURITY DEFINER
// consent gate scan_consent_rejection(scan_id) (F2).
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type pg from 'pg';
import { getTestPool, asRole } from './pg';
import { seedFixtures, clearFixtures, userFor, SITE_A, SITE_B, SCAN_A, SCAN_B, PATIENT_A, CONSENT_VERSION } from './fixtures';

const pool = getTestPool();
const DEV_1 = '00000000-0000-4000-c000-0000000013d1';
const DEV_2 = '00000000-0000-4000-c000-0000000013d2';
const WARD = 'M13-W';
const P_GATE = '00000000-0000-4000-a000-0000000013a1';
const S_GATE = '00000000-0000-4000-b000-0000000013a1';
const S_NOPATIENT = '00000000-0000-4000-b000-0000000013a2';
const OLD = 'm13-old';

beforeAll(async () => {
  await seedFixtures(pool);
  await pool.query('INSERT INTO wards(id, site_id) VALUES ($1,$2) ON CONFLICT DO NOTHING', [WARD, SITE_A]);
  await pool.query('INSERT INTO devices(id, site_id, ward_id) VALUES ($1,$3,$4),($2,$3,$4) ON CONFLICT DO NOTHING', [DEV_1, DEV_2, SITE_A, WARD]);
  await pool.query(`INSERT INTO consent_versions(version,is_current) VALUES ($1,false) ON CONFLICT DO NOTHING`, [OLD]);
  await pool.query(
    `INSERT INTO patients(id,participant_code,pseudonym_id,site_id,cohort) VALUES ($1,'DS-RLSA-01301','ps-m13',$2,'dengue')`,
    [P_GATE, SITE_A],
  );
  await pool.query(
    `INSERT INTO scans(id,client_session_id,patient_id,site_id,captured_at,protocol_version)
     VALUES ($1,gen_random_uuid(),$2,$3,now(),'p1'),($4,gen_random_uuid(),NULL,$3,now(),'p1')`,
    [S_GATE, P_GATE, SITE_A, S_NOPATIENT],
  );
});

afterAll(async () => {
  await pool.query('DELETE FROM scans WHERE id = ANY($1)', [[S_GATE, S_NOPATIENT]]);
  await pool.query('DELETE FROM consents WHERE patient_id = $1', [P_GATE]);
  await pool.query('DELETE FROM patients WHERE id = $1', [P_GATE]);
  await pool.query('DELETE FROM consent_versions WHERE version = $1', [OLD]);
  await pool.query('UPDATE scans SET device_id = NULL WHERE id = $1', [SCAN_A]);
  await pool.query('DELETE FROM devices WHERE id = ANY($1)', [[DEV_1, DEV_2]]);
  await pool.query('DELETE FROM wards WHERE id = $1', [WARD]);
  await clearFixtures(pool);
  await pool.end();
});

const asDevice = <T>(id: string, fn: (c: pg.PoolClient) => Promise<T>, siteId = SITE_A) =>
  asRole(pool, { userId: id, roles: ['device'], siteId }, fn);

describe('0013 scans.device_id guard', () => {
  it('a device may set device_id from NULL to itself', async () => {
    await asDevice(DEV_1, async (c) => {
      const r = await c.query('UPDATE scans SET device_id = $2 WHERE id = $1', [SCAN_A, DEV_1]);
      expect(r.rowCount).toBe(1);
    });
  });

  it('a device may not set device_id to another device', async () => {
    await asDevice(DEV_1, async (c) => {
      await expect(c.query('UPDATE scans SET device_id = $2 WHERE id = $1', [SCAN_A, DEV_2])).rejects.toThrow(/DS_STATE_002/);
    });
  });

  it('a device may not change or clear a device_id that is already set', async () => {
    await pool.query('UPDATE scans SET device_id = $2 WHERE id = $1', [SCAN_A, DEV_2]);
    try {
      await asDevice(DEV_1, async (c) => {
        await expect(c.query('UPDATE scans SET device_id = $2 WHERE id = $1', [SCAN_A, DEV_1])).rejects.toThrow(/DS_STATE_002/);
      });
      await asDevice(DEV_2, async (c) => {
        await expect(c.query('UPDATE scans SET device_id = NULL WHERE id = $1', [SCAN_A])).rejects.toThrow(/DS_STATE_002/);
      });
      // Re-setting the same value is not a change.
      await asDevice(DEV_2, async (c) => {
        expect((await c.query('UPDATE scans SET device_id = $2 WHERE id = $1', [SCAN_A, DEV_2])).rowCount).toBe(1);
      });
    } finally {
      await pool.query('UPDATE scans SET device_id = NULL WHERE id = $1', [SCAN_A]);
    }
  });

  it('site roles are unaffected by the device guard', async () => {
    await asRole(pool, { userId: userFor('nurse_operator'), roles: ['nurse_operator'], siteId: SITE_A }, async (c) => {
      expect((await c.query('UPDATE scans SET device_id = $2 WHERE id = $1', [SCAN_A, DEV_2])).rowCount).toBe(1);
    });
  });
});

const gate = (c: pg.PoolClient, scanId: string) =>
  c.query<{ block_code: string | null; pseudonym: string }>('SELECT block_code, pseudonym FROM scan_consent_rejection($1)', [scanId]);

describe('0013 scan_consent_rejection()', () => {
  it('is SECURITY DEFINER, owned by a NOLOGIN role, with a pinned search_path', async () => {
    const f = (await pool.query(
      `SELECT p.prosecdef, r.rolcanlogin, r.rolsuper, r.rolbypassrls, p.proconfig
         FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner WHERE p.proname = 'scan_consent_rejection'`,
    )).rows[0];
    expect(f.prosecdef).toBe(true);
    expect(f.rolcanlogin).toBe(false);
    expect(f.rolsuper).toBe(false);
    expect(f.rolbypassrls).toBe(false);
    expect(f.proconfig.join(';')).toMatch(/search_path=/);
  });

  it('device and site users of the scan site get the block code and the pseudonym', async () => {
    await asDevice(DEV_1, async (c) => {
      // A device cannot read patients itself...
      expect((await c.query('SELECT 1 FROM patients WHERE id = $1', [PATIENT_A])).rowCount).toBe(0);
      // ...but gets the pseudonym from the gate.
      expect((await gate(c, SCAN_A)).rows).toEqual([{ block_code: null, pseudonym: 'ps-rls-a' }]);
    });
    await asRole(pool, { userId: userFor('clinician'), roles: ['clinician'], siteId: SITE_A }, async (c) => {
      expect((await gate(c, SCAN_A)).rows).toEqual([{ block_code: null, pseudonym: 'ps-rls-a' }]);
    });
  });

  it('other site, no site, or a non-site role -> no row', async () => {
    await asDevice(DEV_1, async (c) => expect((await gate(c, SCAN_B)).rowCount).toBe(0));
    await asDevice(DEV_1, async (c) => expect((await gate(c, SCAN_A)).rowCount).toBe(0), SITE_B);
    await asRole(pool, { userId: userFor('researcher'), roles: ['researcher'], siteId: SITE_A }, async (c) => {
      expect((await gate(c, SCAN_A)).rowCount).toBe(0);
    });
    await asRole(pool, { userId: userFor('system_agent'), roles: ['system_agent'] }, async (c) => {
      expect((await gate(c, SCAN_A)).rowCount).toBe(0);
    });
  });

  it('DS_REG_001 for no consent / not primary / withdrawn; DS_REG_002 for superseded; latest row wins', async () => {
    const at = () => asDevice(DEV_1, async (c) => (await gate(c, S_GATE)).rows[0]);
    expect(await at()).toEqual({ block_code: 'DS_REG_001', pseudonym: 'ps-m13' }); // no consent row
    const add = (version: string, primary: boolean, withdrawn: boolean) =>
      pool.query(
        `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at,withdrawn_at)
         VALUES ($1,$2,$3,now(),${withdrawn ? 'now()' : 'NULL'})`,
        [P_GATE, version, primary],
      );
    await add(CONSENT_VERSION, false, false);
    expect((await at()).block_code).toBe('DS_REG_001');
    await add(OLD, true, false);
    expect((await at()).block_code).toBe('DS_REG_002');
    await add(CONSENT_VERSION, true, false);
    expect((await at()).block_code).toBeNull();
    await add(CONSENT_VERSION, true, true);
    expect((await at()).block_code).toBe('DS_REG_001');
  });

  it('a scan without a patient is blocked DS_REG_001 (fail closed)', async () => {
    await asDevice(DEV_1, async (c) => {
      expect((await gate(c, S_NOPATIENT)).rows).toEqual([{ block_code: 'DS_REG_001', pseudonym: 'n/a' }]);
    });
  });
});
