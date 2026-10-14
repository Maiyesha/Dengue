import type pg from 'pg';

/** Committed RLS fixtures: two sites, one patient and one scan per site, one user per role,
 * and a current primary_research consent for each patient. */
export const SITE_A = 'RLSA-KL';
export const SITE_B = 'RLSB-PG';

export const PATIENT_A = '00000000-0000-4000-a000-00000000000a';
export const PATIENT_B = '00000000-0000-4000-a000-00000000000b';
export const SCAN_A = '00000000-0000-4000-b000-00000000000a';
export const SCAN_B = '00000000-0000-4000-b000-00000000000b';

export const CONSENT_VERSION = 'rls-v1';

export const ROLES = [
  'nurse_operator',
  'clinician',
  'researcher',
  'biostatistician',
  'admin',
  'regulatory_reviewer',
  'system_agent',
] as const;
export type Role = (typeof ROLES)[number];

/** User id for a role; nurse/clinician belong to site A, the rest are site-less. */
export const userFor = (role: Role) => `rls-${role}`;

/** Inserts the fixtures as superuser (committed). Idempotent. */
export async function seedFixtures(pool: pg.Pool): Promise<void> {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    await c.query(`INSERT INTO sites(id,name) VALUES ($1,'Site A'),($2,'Site B') ON CONFLICT DO NOTHING`, [SITE_A, SITE_B]);
    await c.query(
      `INSERT INTO patients(id,participant_code,pseudonym_id,site_id,bed_label,cohort)
       VALUES ($1,'DS-RLSA-00001','ps-rls-a',$3,'A-01','dengue'),
              ($2,'DS-RLSB-00001','ps-rls-b',$4,'B-01','dengue')
       ON CONFLICT DO NOTHING`,
      [PATIENT_A, PATIENT_B, SITE_A, SITE_B],
    );
    for (const role of ROLES) {
      const site = role === 'nurse_operator' || role === 'clinician' ? SITE_A : null;
      await c.query(
        `INSERT INTO app_users(id,idp_subject,role,site_id) VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING`,
        [userFor(role), 'sub-' + userFor(role), role, site],
      );
    }
    await c.query(
      `INSERT INTO scans(id,client_session_id,patient_id,site_id,captured_at,protocol_version)
       VALUES ($1,gen_random_uuid(),$3,$5,now(),'p1'),
              ($2,gen_random_uuid(),$4,$6,now(),'p1')
       ON CONFLICT DO NOTHING`,
      [SCAN_A, SCAN_B, PATIENT_A, PATIENT_B, SITE_A, SITE_B],
    );
    await c.query(`INSERT INTO consent_versions(version,is_current) VALUES ($1,true) ON CONFLICT DO NOTHING`, [CONSENT_VERSION]);
    await c.query(
      `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at)
       SELECT pid, $3, true, now() - interval '1 day' FROM unnest(ARRAY[$1,$2]::uuid[]) pid
       WHERE NOT EXISTS (SELECT 1 FROM consents WHERE patient_id = pid)`,
      [PATIENT_A, PATIENT_B, CONSENT_VERSION],
    );
    await c.query('COMMIT');
  } catch (e) {
    await c.query('ROLLBACK');
    throw e;
  } finally {
    c.release();
  }
}

/** Removes the fixtures so later test files see a clean DB. */
export async function clearFixtures(pool: pg.Pool): Promise<void> {
  await pool.query('DELETE FROM consents WHERE patient_id = ANY($1)', [[PATIENT_A, PATIENT_B]]);
  await pool.query('DELETE FROM consent_versions WHERE version = $1', [CONSENT_VERSION]);
  await pool.query('DELETE FROM scans WHERE id = ANY($1)', [[SCAN_A, SCAN_B]]);
  await pool.query('DELETE FROM patients WHERE id = ANY($1)', [[PATIENT_A, PATIENT_B]]);
  await pool.query('DELETE FROM app_users WHERE id = ANY($1)', [ROLES.map(userFor)]);
  await pool.query('DELETE FROM sites WHERE id = ANY($1)', [[SITE_A, SITE_B]]);
}
