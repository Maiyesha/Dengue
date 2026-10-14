import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type pg from 'pg';
import { getTestPool, asRole } from './pg';
import {
  seedFixtures, clearFixtures, userFor, SITE_A, SITE_B, SCAN_A, SCAN_B, PATIENT_A, PATIENT_B, type Role,
} from './fixtures';

const pool = getTestPool();

beforeAll(async () => { await seedFixtures(pool); });
afterAll(async () => {
  await clearFixtures(pool);
  await pool.end();
});

const as = <T>(role: Role, fn: (c: pg.PoolClient) => Promise<T>, siteId?: string) =>
  asRole(pool, { userId: userFor(role), roles: [role], siteId }, fn);

const count = async (c: pg.PoolClient, sql: string, params: unknown[] = []) =>
  (await c.query(`SELECT count(*)::int AS n FROM (${sql}) q`, params)).rows[0].n as number;

/** Runs sql as the superuser inside asRole's transaction (rolled back with it). */
const asSuper = async (c: pg.PoolClient, sql: string, params: unknown[] = []) => {
  await c.query('RESET ROLE');
  try {
    return await c.query(sql, params);
  } finally {
    await c.query('SET LOCAL ROLE app_api');
  }
};

const insertReview = (c: pg.PoolClient, scanId: string, reviewer: string) =>
  c.query(
    `INSERT INTO scan_reviews(scan_id,reviewer_user_id,action,webauthn_assertion_hash)
     VALUES ($1,$2,'confirm',repeat('a',64))`,
    [scanId, reviewer],
  );

describe('row level security', () => {
  // ---- brief tests ----
  it('clinician site A sees 1 patient, not site B', async () => {
    await as('clinician', async (c) => {
      const r = await c.query('SELECT id, site_id FROM patients');
      expect(r.rows).toEqual([{ id: PATIENT_A, site_id: SITE_A }]);
    }, SITE_A);
  });

  it('clinician with no site setting sees 0 patients', async () => {
    // Setting never provided.
    await as('clinician', async (c) => {
      expect(await count(c, 'SELECT * FROM patients')).toBe(0);
      expect(await count(c, 'SELECT * FROM scans')).toBe(0);
    });
    // Setting explicitly reset to empty.
    await as('clinician', async (c) => {
      await c.query(`SELECT set_config('app.site_id', '', true)`);
      expect(await count(c, 'SELECT * FROM patients')).toBe(0);
      expect(await count(c, 'SELECT * FROM scans')).toBe(0);
      expect(await count(c, 'SELECT * FROM scan_step_attempts')).toBe(0);
    }, SITE_A);
  });

  it('nurse_operator cannot insert scan_reviews', async () => {
    await expect(
      as('nurse_operator', (c) => insertReview(c, SCAN_A, userFor('nurse_operator')), SITE_A),
    ).rejects.toMatchObject({ code: '42501' });
  });

  it('researcher selecting patients sees 0 rows', async () => {
    await as('researcher', async (c) => {
      expect(await count(c, 'SELECT * FROM patients')).toBe(0);
      expect(await count(c, 'SELECT * FROM scans')).toBe(0);
      expect(await count(c, 'SELECT * FROM features')).toBe(0);
      expect(await count(c, 'SELECT * FROM sqi_checks')).toBe(0);
    }, SITE_A);
  });

  it('researcher sees research_patients without participant_code column', async () => {
    await as('researcher', async (c) => {
      const r = await c.query(
        'SELECT * FROM research_patients WHERE pseudonym_id IN ($1,$2) ORDER BY pseudonym_id',
        ['ps-rls-a', 'ps-rls-b'],
      );
      expect(r.fields.map((f) => f.name).sort()).toEqual(['cohort', 'pseudonym_id', 'site_bucket', 'status']);
      expect(r.rows).toEqual([
        { pseudonym_id: 'ps-rls-a', cohort: 'dengue', status: 'active', site_bucket: 'RLSA' },
        { pseudonym_id: 'ps-rls-b', cohort: 'dengue', status: 'active', site_bucket: 'RLSB' },
      ]);
    });
  });

  it('admin sees both patients', async () => {
    await as('admin', async (c) => {
      expect(await count(c, 'SELECT * FROM patients WHERE site_id IN ($1,$2)', [SITE_A, SITE_B])).toBe(2);
    });
  });

  // ---- additional coverage ----
  it('clinician can insert a scan_review for own site but not for site B', async () => {
    await as('clinician', async (c) => {
      await insertReview(c, SCAN_A, userFor('clinician'));
      expect(await count(c, 'SELECT * FROM scan_reviews WHERE scan_id=$1', [SCAN_A])).toBe(1);
      await expect(insertReview(c, SCAN_B, userFor('clinician'))).rejects.toMatchObject({ code: '42501' });
    }, SITE_A);
  });

  it('nurse_operator cannot insert a patient into another site', async () => {
    await expect(
      as('nurse_operator', (c) =>
        c.query(`INSERT INTO patients(participant_code,pseudonym_id,site_id) VALUES ('DS-RLSB-00002','ps-x',$1)`, [SITE_B]),
      SITE_A),
    ).rejects.toMatchObject({ code: '42501' });
  });

  it('nurse_operator cannot move a patient to another site', async () => {
    await expect(
      as('nurse_operator', (c) => c.query('UPDATE patients SET site_id=$1 WHERE id=$2', [SITE_B, PATIENT_A]), SITE_A),
    ).rejects.toMatchObject({ code: '42501' });
  });

  it('research_scans and research_features span sites for researcher and biostatistician', async () => {
    for (const role of ['researcher', 'biostatistician'] as const) {
      await as(role, async (c) => {
        const r = await c.query('SELECT * FROM research_scans WHERE id IN ($1,$2)', [SCAN_A, SCAN_B]);
        expect(r.rows).toHaveLength(2);
        expect(r.fields.map((f) => f.name).sort()).toEqual(['captured_at', 'id', 'protocol_version', 'pseudonym_id', 'site_bucket', 'status']);
        const f = await c.query('SELECT * FROM research_features LIMIT 0');
        expect(f.fields.map((x) => x.name).sort()).toEqual(
          ['domain', 'feature_availability_timestamp', 'name', 'pipeline_version', 'scan_id', 'value'],
        );
      });
    }
  });

  it('research views return 0 rows for nurse_operator and clinician', async () => {
    for (const role of ['nurse_operator', 'clinician'] as const) {
      await as(role, async (c) => {
        expect(await count(c, 'SELECT * FROM research_patients')).toBe(0);
        expect(await count(c, 'SELECT * FROM research_scans')).toBe(0);
      }, SITE_A);
    }
  });

  it('system_agent reads and updates scans across sites but sees no patients', async () => {
    await as('system_agent', async (c) => {
      expect(await count(c, 'SELECT * FROM scans WHERE id IN ($1,$2)', [SCAN_A, SCAN_B])).toBe(2);
      const u = await c.query(`UPDATE scans SET status='quality_pending' WHERE id IN ($1,$2)`, [SCAN_A, SCAN_B]);
      expect(u.rowCount).toBe(2);
      expect(await count(c, 'SELECT * FROM patients')).toBe(0);
    });
  });

  it('regulatory_reviewer reads all but cannot update', async () => {
    await as('regulatory_reviewer', async (c) => {
      expect(await count(c, 'SELECT * FROM scans WHERE id IN ($1,$2)', [SCAN_A, SCAN_B])).toBe(2);
      const u = await c.query(`UPDATE patients SET cohort='x' WHERE id=$1`, [PATIENT_A]);
      expect(u.rowCount).toBe(0);
    });
  });

  it('admin cannot DELETE clinical rows', async () => {
    await expect(
      as('admin', (c) => c.query('DELETE FROM patients WHERE id=$1', [PATIENT_A])),
    ).rejects.toMatchObject({ code: '42501' });
  });

  it('RLS is enabled and forced on every participant-data table', async () => {
    const tables = [
      'patients', 'consents', 'scans', 'scan_step_attempts', 'artefacts', 'clinical_observations',
      'lab_values', 'sqi_checks', 'features', 'scan_reviews',
    ];
    const r = await pool.query(
      `SELECT relname FROM pg_class WHERE relname = ANY($1) AND relnamespace='public'::regnamespace
         AND relrowsecurity AND relforcerowsecurity`,
      [tables],
    );
    expect(r.rows.map((x) => x.relname).sort()).toEqual([...tables].sort());
  });

  it('app_api still has no access to the vault', async () => {
    await expect(
      as('admin', (c) => c.query('SELECT * FROM vault.patient_identifiers')),
    ).rejects.toMatchObject({ code: '42501' });
  });

  // ---- fix round 1: immutable linkage columns ----
  it('system_agent cannot change scans.site_id (DS_STATE_002)', async () => {
    await expect(
      as('system_agent', (c) => c.query('UPDATE scans SET site_id=$1 WHERE id=$2', [SITE_B, SCAN_A])),
    ).rejects.toThrow(/DS_STATE_002/);
  });

  it('system_agent cannot change scans.patient_id (DS_STATE_002)', async () => {
    await expect(
      as('system_agent', (c) => c.query('UPDATE scans SET patient_id=$1 WHERE id=$2', [PATIENT_B, SCAN_A])),
    ).rejects.toThrow(/DS_STATE_002/);
  });

  it('system_agent cannot change features.scan_id (DS_STATE_002)', async () => {
    await expect(
      as('system_agent', async (c) => {
        await c.query(
          `INSERT INTO features(scan_id,domain,name,value,pipeline_version,feature_availability_timestamp)
           VALUES ($1,'rppg_face','hr_bpm',72,'pv1',now())`,
          [SCAN_A],
        );
        expect(await count(c, 'SELECT * FROM features WHERE scan_id=$1', [SCAN_A])).toBe(1);
        await c.query('UPDATE features SET scan_id=$1 WHERE scan_id=$2', [SCAN_B, SCAN_A]);
      }),
    ).rejects.toThrow(/DS_STATE_002/);
  });

  it('system_agent can still update non-linkage columns of features', async () => {
    await as('system_agent', async (c) => {
      await c.query(
        `INSERT INTO features(scan_id,domain,name,value,pipeline_version,feature_availability_timestamp)
         VALUES ($1,'rppg_face','hr_bpm',72,'pv1',now())`,
        [SCAN_A],
      );
      const u = await c.query(`UPDATE features SET value=73 WHERE scan_id=$1`, [SCAN_A]);
      expect(u.rowCount).toBe(1);
    });
  });

  it('linkage columns are immutable for site roles too', async () => {
    await expect(
      as('clinician', (c) => c.query('UPDATE scans SET patient_id=NULL WHERE id=$1', [SCAN_A]), SITE_A),
    ).rejects.toThrow(/DS_STATE_002/);
  });

  // ---- fix round 1: consent-gated research views ----
  it('research_patients and research_scans hide a withdrawn participant', async () => {
    await as('researcher', async (c) => {
      expect(await count(c, 'SELECT * FROM research_patients WHERE pseudonym_id=$1', ['ps-rls-a'])).toBe(1);
      expect(await count(c, 'SELECT * FROM research_scans WHERE id=$1', [SCAN_A])).toBe(1);
      await asSuper(
        c,
        `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at,withdrawn_at)
         VALUES ($1,'rls-v1',true,now(),now())`,
        [PATIENT_A],
      );
      expect(await count(c, 'SELECT * FROM research_patients WHERE pseudonym_id=$1', ['ps-rls-a'])).toBe(0);
      expect(await count(c, 'SELECT * FROM research_scans WHERE id=$1', [SCAN_A])).toBe(0);
      // Other site's participant is unaffected.
      expect(await count(c, 'SELECT * FROM research_scans WHERE id=$1', [SCAN_B])).toBe(1);
    });
  });

  it('research views hide a participant whose latest consent has primary_research=false', async () => {
    await as('biostatistician', async (c) => {
      await asSuper(
        c,
        `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at)
         VALUES ($1,'rls-v1',false,now())`,
        [PATIENT_B],
      );
      expect(await count(c, 'SELECT * FROM research_patients WHERE pseudonym_id=$1', ['ps-rls-b'])).toBe(0);
      expect(await count(c, 'SELECT * FROM research_scans WHERE id=$1', [SCAN_B])).toBe(0);
    });
  });

  it('research views hide a participant with no consent row', async () => {
    await as('researcher', async (c) => {
      await asSuper(c, 'DELETE FROM consents WHERE patient_id=$1', [PATIENT_B]);
      expect(await count(c, 'SELECT * FROM research_patients WHERE pseudonym_id=$1', ['ps-rls-b'])).toBe(0);
    });
  });

  it('research_scans exposes pseudonym_id but not participant_code', async () => {
    await as('researcher', async (c) => {
      const r = await c.query('SELECT * FROM research_scans WHERE id=$1', [SCAN_A]);
      const cols = r.fields.map((f) => f.name);
      expect(cols).toContain('pseudonym_id');
      expect(cols).not.toContain('participant_code');
      expect(cols).not.toContain('patient_id');
      expect(r.rows[0].pseudonym_id).toBe('ps-rls-a');
    });
  });

  it('app_api cannot read the internal research_consented_patients view', async () => {
    await expect(
      as('researcher', (c) => c.query('SELECT * FROM research_consented_patients')),
    ).rejects.toMatchObject({ code: '42501' });
  });
});
