// Final-review hardening (migration 0007): consent versions, SQI source, scan state authority,
// append-only consents, research-view scan exclusion, devices/app_users exposure, patient id
// immutability, scans.site_id FK, and cross-site child-table coverage.
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
  // On error the transaction is aborted and asRole rolls it back; no role restore needed.
  const r = await c.query(sql, params);
  await c.query('SET LOCAL ROLE app_api');
  return r;
};

/** Switches the effective app role inside the current asRole transaction. */
const switchTo = async (c: pg.PoolClient, role: Role, siteId?: string) => {
  await c.query(`SELECT set_config('app.user_id',$1,true), set_config('app.roles',$2,true),
                        set_config('app.site_id',$3,true)`, [userFor(role), role, siteId ?? '']);
};

/** Walks a scan through legal transitions as the superuser (exempt from role authority). */
const walk = async (c: pg.PoolClient, scanId: string, statuses: string[]) => {
  for (const s of statuses) await asSuper(c, 'UPDATE scans SET status=$2::scan_status WHERE id=$1', [scanId, s]);
};
const TO_REVIEW_PENDING = ['quality_pending', 'quality_passed', 'feature_pending', 'feature_complete', 'review_pending'];

const status = async (c: pg.PoolClient, scanId: string) =>
  (await asSuper(c, 'SELECT status FROM scans WHERE id=$1', [scanId])).rows[0].status as string;

// ------------------------------------------------------------------ item 1
describe('1. consent current version', () => {
  it('a second current consent version is rejected', async () => {
    await as('admin', async (c) => {
      await asSuper(c, 'UPDATE consent_versions SET is_current=false');
      await asSuper(c, `INSERT INTO consent_versions(version,is_current) VALUES ('h-v1',true)`);
      await expect(
        asSuper(c, `INSERT INTO consent_versions(version,is_current) VALUES ('h-v2',true)`),
      ).rejects.toMatchObject({ code: '23505' });
    });
  });

  it('v1 -> v2 re-consent shows consent_version v2 = current', async () => {
    await as('clinician', async (c) => {
      await asSuper(c, 'UPDATE consent_versions SET is_current=false');
      await asSuper(c, `INSERT INTO consent_versions(version,is_current) VALUES ('h-v1',true),('h-v2',false)`);
      await c.query(
        `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at) VALUES ($1,'h-v1',true,now())`,
        [PATIENT_A],
      );
      let r = await c.query('SELECT consent_version, current_version FROM patient_consent_status WHERE patient_id=$1', [PATIENT_A]);
      expect(r.rows[0]).toEqual({ consent_version: 'h-v1', current_version: 'h-v1' });
      await asSuper(c, `UPDATE consent_versions SET is_current = (version = 'h-v2')`);
      r = await c.query('SELECT consent_version, current_version FROM patient_consent_status WHERE patient_id=$1', [PATIENT_A]);
      expect(r.rows[0]).toEqual({ consent_version: 'h-v1', current_version: 'h-v2' });
      await c.query(
        `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at) VALUES ($1,'h-v2',true,now())`,
        [PATIENT_A],
      );
      r = await c.query('SELECT consent_version, current_version FROM patient_consent_status WHERE patient_id=$1', [PATIENT_A]);
      expect(r.rows[0]).toEqual({ consent_version: 'h-v2', current_version: 'h-v2' });
    }, SITE_A);
  });
});

// ------------------------------------------------------------------ item 2
describe('2. sqi_checks source forgery', () => {
  const ins = (c: pg.PoolClient, source: string) =>
    c.query(
      `INSERT INTO sqi_checks(scan_id,step,attempt,check_id,source,passed)
       VALUES ($1,'neutral_face',1,'face_detection',$2,true)`,
      [SCAN_A, source],
    );

  it("nurse inserting source='server' is rejected", async () => {
    await expect(as('nurse_operator', (c) => ins(c, 'server'), SITE_A)).rejects.toMatchObject({ code: '42501' });
  });
  it("nurse inserting source='device' is allowed", async () => {
    await as('nurse_operator', (c) => ins(c, 'device'), SITE_A);
  });
  it("system_agent inserting source='device' is rejected", async () => {
    await expect(as('system_agent', (c) => ins(c, 'device'))).rejects.toMatchObject({ code: '42501' });
  });
  it("system_agent inserting source='server' is allowed", async () => {
    await as('system_agent', (c) => ins(c, 'server'));
  });
  it('system_agent cannot rewrite a device-side row', async () => {
    await as('system_agent', async (c) => {
      await asSuper(c, `INSERT INTO sqi_checks(scan_id,step,attempt,check_id,source,passed)
                        VALUES ($1,'neutral_face',1,'face_detection','device',true)`, [SCAN_A]);
      const u = await c.query(`UPDATE sqi_checks SET passed=false WHERE scan_id=$1 AND source='device'`, [SCAN_A]);
      expect(u.rowCount).toBe(0);
    });
  });
});

// ------------------------------------------------------------------ item 3
describe('3. scan state-machine authority', () => {
  const insScan = (c: pg.PoolClient, st?: string) =>
    c.query(
      `INSERT INTO scans(client_session_id,patient_id,site_id,captured_at,protocol_version${st ? ',status' : ''})
       VALUES (gen_random_uuid(),$1,$2,now(),'p1'${st ? ',$3::scan_status' : ''})`,
      st ? [PATIENT_A, SITE_A, st] : [PATIENT_A, SITE_A],
    );
  const upd = (c: pg.PoolClient, st: string, id = SCAN_A) =>
    c.query('UPDATE scans SET status=$2::scan_status WHERE id=$1', [id, st]);

  it("nurse INSERT with status='reviewed' is rejected (DS_STATE_003)", async () => {
    await expect(as('nurse_operator', (c) => insScan(c, 'reviewed'), SITE_A)).rejects.toThrow(/DS_STATE_003/);
  });
  it('nurse INSERT with default capture_pending is allowed', async () => {
    await as('nurse_operator', (c) => insScan(c), SITE_A);
  });
  it('nurse capture_pending -> quality_pending allowed', async () => {
    await as('nurse_operator', async (c) => {
      await upd(c, 'quality_pending');
      expect(await status(c, SCAN_A)).toBe('quality_pending');
    }, SITE_A);
  });
  it('system_agent capture_pending -> quality_pending rejected (DS_STATE_003)', async () => {
    await expect(as('system_agent', (c) => upd(c, 'quality_pending'))).rejects.toThrow(/DS_STATE_003/);
  });
  it('nurse quality_pending -> quality_passed rejected (DS_STATE_003)', async () => {
    await expect(as('nurse_operator', async (c) => {
      await walk(c, SCAN_A, ['quality_pending']);
      await upd(c, 'quality_passed');
    }, SITE_A)).rejects.toThrow(/DS_STATE_003/);
  });
  it('system_agent quality_pending -> quality_passed -> ... -> review_pending allowed', async () => {
    await as('system_agent', async (c) => {
      await walk(c, SCAN_A, ['quality_pending']);
      for (const s of ['quality_passed', 'feature_pending', 'feature_complete', 'review_pending']) await upd(c, s);
      expect(await status(c, SCAN_A)).toBe('review_pending');
    });
  });
  it('nurse review_pending -> reviewed rejected (DS_STATE_003)', async () => {
    await expect(as('nurse_operator', async (c) => {
      await walk(c, SCAN_A, TO_REVIEW_PENDING);
      await upd(c, 'reviewed');
    }, SITE_A)).rejects.toThrow(/DS_STATE_003/);
  });
  it('system_agent review_pending -> reviewed rejected (DS_STATE_003)', async () => {
    await expect(as('system_agent', async (c) => {
      await walk(c, SCAN_A, TO_REVIEW_PENDING);
      await upd(c, 'reviewed');
    })).rejects.toThrow(/DS_STATE_003/);
  });
  it('clinician review_pending -> reviewed -> archived allowed', async () => {
    await as('clinician', async (c) => {
      await walk(c, SCAN_A, TO_REVIEW_PENDING);
      await upd(c, 'reviewed');
      await upd(c, 'archived');
      expect(await status(c, SCAN_A)).toBe('archived');
    }, SITE_A);
  });
  it('nurse reviewed -> archived rejected (DS_STATE_003)', async () => {
    await expect(as('nurse_operator', async (c) => {
      await walk(c, SCAN_A, [...TO_REVIEW_PENDING, 'reviewed']);
      await upd(c, 'archived');
    }, SITE_A)).rejects.toThrow(/DS_STATE_003/);
  });
  it('nurse may revoke a non-archived scan', async () => {
    await as('nurse_operator', async (c) => {
      await walk(c, SCAN_A, ['quality_pending', 'quality_passed']);
      await upd(c, 'revoked');
      expect(await status(c, SCAN_A)).toBe('revoked');
    }, SITE_A);
  });
  it('system_agent may not revoke (DS_STATE_003)', async () => {
    await expect(as('system_agent', (c) => upd(c, 'revoked'))).rejects.toThrow(/DS_STATE_003/);
  });
  it('archived -> revoked is illegal (DS_STATE_001), not an authority error', async () => {
    await expect(as('clinician', async (c) => {
      await walk(c, SCAN_A, [...TO_REVIEW_PENDING, 'reviewed', 'archived']);
      await upd(c, 'revoked');
    }, SITE_A)).rejects.toThrow(/DS_STATE_001/);
  });
});

// ------------------------------------------------------------------ item 4
describe('4. consents append-only, clinician/admin writes', () => {
  const insConsent = (c: pg.PoolClient, pid: string, withdrawn = false) =>
    c.query(
      `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at,withdrawn_at)
       VALUES ($1,'rls-v1',true,now(),${withdrawn ? 'now()' : 'NULL'})`,
      [pid],
    );

  it('nurse cannot insert consents', async () => {
    await expect(as('nurse_operator', (c) => insConsent(c, PATIENT_A), SITE_A)).rejects.toMatchObject({ code: '42501' });
  });
  it('nurse cannot update consents', async () => {
    await expect(
      as('nurse_operator', (c) => c.query('UPDATE consents SET primary_research=false WHERE patient_id=$1', [PATIENT_A]), SITE_A),
    ).rejects.toMatchObject({ code: '42501' });
  });
  it('clinician cannot update consents', async () => {
    await expect(
      as('clinician', (c) => c.query('UPDATE consents SET withdrawn_at=now() WHERE patient_id=$1', [PATIENT_A]), SITE_A),
    ).rejects.toMatchObject({ code: '42501' });
  });
  it('clinician inserts for own site, not for site B', async () => {
    await as('clinician', async (c) => {
      await insConsent(c, PATIENT_A);
      await expect(insConsent(c, PATIENT_B)).rejects.toMatchObject({ code: '42501' });
    }, SITE_A);
  });
  it('admin inserts for the patient of its app.site_id only', async () => {
    await as('admin', async (c) => {
      await insConsent(c, PATIENT_A);
      await expect(insConsent(c, PATIENT_B)).rejects.toMatchObject({ code: '42501' });
    }, SITE_A);
    await expect(as('admin', (c) => insConsent(c, PATIENT_A))).rejects.toMatchObject({ code: '42501' });
  });
  it('consents.recorded_at is set by the database', async () => {
    await as('clinician', async (c) => {
      const r = await c.query(
        `INSERT INTO consents(patient_id,consent_version,primary_research,consented_at)
         VALUES ($1,'rls-v1',true,now()) RETURNING recorded_at`,
        [PATIENT_A],
      );
      expect(r.rows[0].recorded_at).toBeInstanceOf(Date);
    }, SITE_A);
  });
  it('withdrawal row followed by nothing -> withdrawn', async () => {
    await as('clinician', async (c) => {
      await insConsent(c, PATIENT_A, true);
      const r = await c.query('SELECT withdrawn FROM patient_consent_status WHERE patient_id=$1', [PATIENT_A]);
      expect(r.rows[0].withdrawn).toBe(true);
      await switchTo(c, 'researcher');
      expect(await count(c, 'SELECT * FROM research_patients WHERE pseudonym_id=$1', ['ps-rls-a'])).toBe(0);
    }, SITE_A);
  });
  it('withdrawal then later re-consent (same consented_at) -> not withdrawn', async () => {
    // Repeat to make an id-order tie-break failure overwhelmingly likely to show.
    for (let i = 0; i < 5; i++) {
      await as('clinician', async (c) => {
        await insConsent(c, PATIENT_A, true);
        await insConsent(c, PATIENT_A, false);
        const r = await c.query('SELECT withdrawn FROM patient_consent_status WHERE patient_id=$1', [PATIENT_A]);
        expect(r.rows[0].withdrawn).toBe(false);
        await switchTo(c, 'researcher');
        expect(await count(c, 'SELECT * FROM research_patients WHERE pseudonym_id=$1', ['ps-rls-a'])).toBe(1);
      }, SITE_A);
    }
  });
  it('recreated views keep security_invoker / research_definer ownership', async () => {
    const r = await pool.query(
      `SELECT c.relname, pg_get_userbyid(c.relowner) AS owner, c.reloptions
         FROM pg_class c WHERE c.relname = ANY($1) ORDER BY c.relname`,
      [['patient_consent_status', 'research_consented_patients', 'research_scans', 'research_features', 'research_sqi_checks']],
    );
    const by = Object.fromEntries(r.rows.map((x) => [x.relname, x]));
    expect(by.patient_consent_status.reloptions).toEqual(['security_invoker=true']);
    for (const v of ['research_consented_patients', 'research_scans', 'research_features', 'research_sqi_checks']) {
      expect(by[v].owner).toBe('research_definer');
      expect(by[v].reloptions).toEqual(['security_barrier=true']);
    }
  });
});

// ------------------------------------------------------------------ item 5
describe('5. research views exclude revoked / excluded scans', () => {
  const seedChildren = async (c: pg.PoolClient) => {
    await asSuper(c, `INSERT INTO features(scan_id,domain,name,value,pipeline_version,feature_availability_timestamp)
                      VALUES ($1,'rppg_face','hr_bpm',72,'pv1',now())`, [SCAN_A]);
    await asSuper(c, `INSERT INTO sqi_checks(scan_id,step,attempt,check_id,source,passed)
                      VALUES ($1,'neutral_face',1,'face_detection','server',true)`, [SCAN_A]);
  };
  const visible = async (c: pg.PoolClient) => [
    await count(c, 'SELECT * FROM research_scans WHERE id=$1', [SCAN_A]),
    await count(c, 'SELECT * FROM research_features WHERE scan_id=$1', [SCAN_A]),
    await count(c, 'SELECT * FROM research_sqi_checks WHERE scan_id=$1', [SCAN_A]),
  ];

  it('revoked scan disappears from research_scans/features/sqi_checks', async () => {
    await as('researcher', async (c) => {
      await seedChildren(c);
      expect(await visible(c)).toEqual([1, 1, 1]);
      await walk(c, SCAN_A, ['revoked']);
      expect(await visible(c)).toEqual([0, 0, 0]);
    });
  });
  it('excluded scan disappears from research_scans/features/sqi_checks', async () => {
    await as('researcher', async (c) => {
      await seedChildren(c);
      await walk(c, SCAN_A, [...TO_REVIEW_PENDING, 'excluded']);
      expect(await visible(c)).toEqual([0, 0, 0]);
    });
  });
});

// ------------------------------------------------------------------ item 9
describe('9. devices / app_users exposure', () => {
  const DEV_A = '00000000-0000-4000-c000-00000000000a';
  const DEV_B = '00000000-0000-4000-c000-00000000000b';
  const seedDevices = async (c: pg.PoolClient) => {
    await asSuper(c, `INSERT INTO wards(id,site_id) VALUES ('h-wa',$1),('h-wb',$2)`, [SITE_A, SITE_B]);
    await asSuper(c, `INSERT INTO devices(id,site_id,ward_id,app_attest_key_id,attest_public_key,push_token)
                      VALUES ($1,$3,'h-wa','k-a','\\x01','tok-a'),($2,$4,'h-wb','k-b','\\x02','tok-b')`,
      [DEV_A, DEV_B, SITE_A, SITE_B]);
  };
  const SAFE = 'SELECT id, site_id, ward_id, app_attest_key_id, assertion_counter, status FROM devices WHERE id IN ($1,$2)';

  it('push_token and attest_public_key are not readable by app_api', async () => {
    for (const col of ['push_token', 'attest_public_key']) {
      await expect(as('admin', async (c) => {
        await seedDevices(c);
        await c.query(`SELECT ${col} FROM devices`);
      })).rejects.toMatchObject({ code: '42501' });
    }
  });
  it('site role reads only own-site devices; system_agent reads all; researcher none', async () => {
    await as('nurse_operator', async (c) => {
      await seedDevices(c);
      const r = await c.query(SAFE, [DEV_A, DEV_B]);
      expect(r.rows.map((x) => x.id)).toEqual([DEV_A]);
      await switchTo(c, 'system_agent');
      expect((await c.query(SAFE, [DEV_A, DEV_B])).rowCount).toBe(2);
      await switchTo(c, 'researcher');
      expect((await c.query(SAFE, [DEV_A, DEV_B])).rowCount).toBe(0);
    }, SITE_A);
  });
  it('researcher and biostatistician see no app_users rows', async () => {
    for (const role of ['researcher', 'biostatistician'] as const) {
      await as(role, async (c) => {
        expect(await count(c, 'SELECT id FROM app_users')).toBe(0);
      });
    }
  });
  it('site role sees own-site app_users; admin sees all', async () => {
    const ids = ['nurse_operator', 'clinician', 'researcher', 'admin'].map((r) => userFor(r as Role));
    await as('clinician', async (c) => {
      const r = await c.query('SELECT id, role, site_id FROM app_users WHERE id = ANY($1) ORDER BY id', [ids]);
      expect(r.rows.map((x) => x.id)).toEqual([userFor('clinician'), userFor('nurse_operator')]);
      await switchTo(c, 'admin');
      expect(await count(c, 'SELECT id FROM app_users WHERE id = ANY($1)', [ids])).toBe(4);
    }, SITE_A);
  });
  it('app_users.idp_subject is not readable by app_api', async () => {
    await expect(as('admin', (c) => c.query('SELECT idp_subject FROM app_users'))).rejects.toMatchObject({ code: '42501' });
  });
});

// ------------------------------------------------------------------ item 10
describe('10. patient identifiers immutable', () => {
  it('clinician cannot change pseudonym_id (DS_STATE_002)', async () => {
    await expect(
      as('clinician', (c) => c.query(`UPDATE patients SET pseudonym_id='ps-new' WHERE id=$1`, [PATIENT_A]), SITE_A),
    ).rejects.toThrow(/DS_STATE_002/);
  });
  it('clinician cannot change participant_code (DS_STATE_002)', async () => {
    await expect(
      as('clinician', (c) => c.query(`UPDATE patients SET participant_code='DS-RLSA-00099' WHERE id=$1`, [PATIENT_A]), SITE_A),
    ).rejects.toThrow(/DS_STATE_002/);
  });
  it('other patient columns remain updatable', async () => {
    await as('clinician', async (c) => {
      const u = await c.query(`UPDATE patients SET bed_label='A-02' WHERE id=$1`, [PATIENT_A]);
      expect(u.rowCount).toBe(1);
    }, SITE_A);
  });
});

// ------------------------------------------------------------------ item 11
describe('11. scans.site_id FK', () => {
  it('a scan for an unknown site is rejected', async () => {
    await expect(as('admin', (c) => asSuper(c,
      `INSERT INTO scans(client_session_id,site_id,captured_at,protocol_version) VALUES (gen_random_uuid(),'NO-SUCH',now(),'p1')`,
    ))).rejects.toMatchObject({ code: '23503' });
  });
});

// ------------------------------------------------------------------ item 12
describe('12. cross-site child tables and research row gate', () => {
  it('site-A clinician sees 0 site-B rows in every child table', async () => {
    await as('clinician', async (c) => {
      await asSuper(c, `INSERT INTO clinical_observations(patient_id,observer_user_id,measured_at,vital,value,source_device_type)
                        VALUES ($1,'u',now(),'hr',80,'ox')`, [PATIENT_B]);
      await asSuper(c, `INSERT INTO features(scan_id,domain,name,value,pipeline_version,feature_availability_timestamp)
                        VALUES ($1,'rppg_face','hr_bpm',72,'pv1',now())`, [SCAN_B]);
      await asSuper(c, `INSERT INTO artefacts(scan_id,step,attempt,kind,sha256,object_key)
                        VALUES ($1,'neutral_face',1,'video',repeat('a',64),'h-obj-b')`, [SCAN_B]);
      await asSuper(c, `INSERT INTO sqi_checks(scan_id,step,attempt,check_id,source,passed)
                        VALUES ($1,'neutral_face',1,'face_detection','device',true)`, [SCAN_B]);
      await asSuper(c, `INSERT INTO scan_reviews(scan_id,reviewer_user_id,action,webauthn_assertion_hash)
                        VALUES ($1,'u','confirm',repeat('a',64))`, [SCAN_B]);
      const checks: Array<[string, string, string]> = [
        ['consents', 'patient_id', PATIENT_B],
        ['clinical_observations', 'patient_id', PATIENT_B],
        ['features', 'scan_id', SCAN_B],
        ['artefacts', 'scan_id', SCAN_B],
        ['sqi_checks', 'scan_id', SCAN_B],
        ['scan_reviews', 'scan_id', SCAN_B],
      ];
      for (const [t, col, id] of checks) {
        const sql = `SELECT * FROM ${t} WHERE ${col}=$1`;
        expect((await asSuper(c, `SELECT count(*)::int n FROM (${sql}) q`, [id])).rows[0].n, `${t} control`).toBeGreaterThan(0);
        expect(await count(c, sql, [id]), t).toBe(0);
      }
    }, SITE_A);
  });

  it('research_features returns rows for researcher, none for system_agent or empty roles', async () => {
    await as('researcher', async (c) => {
      await asSuper(c, `INSERT INTO features(scan_id,domain,name,value,pipeline_version,feature_availability_timestamp)
                        VALUES ($1,'rppg_face','hr_bpm',72,'pv1',now())`, [SCAN_A]);
      expect(await count(c, 'SELECT * FROM research_features WHERE scan_id=$1', [SCAN_A])).toBe(1);
      await switchTo(c, 'system_agent');
      expect(await count(c, 'SELECT * FROM research_features WHERE scan_id=$1', [SCAN_A])).toBe(0);
      await c.query(`SELECT set_config('app.roles','',true)`);
      expect(await count(c, 'SELECT * FROM research_features WHERE scan_id=$1', [SCAN_A])).toBe(0);
    });
  });
});
