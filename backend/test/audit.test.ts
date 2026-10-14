import { describe, it, expect, afterAll } from 'vitest';
import type pg from 'pg';
import { getTestPool, asRole, type RoleCtx } from './pg';

// Reads of clinical_audit_log are limited to admin / regulatory_reviewer (0007), so the
// read-back tests run as regulatory_reviewer; site roles may only append.
const ctx = { userId: 'u-audit', roles: ['regulatory_reviewer'] };
const nurse: RoleCtx = { userId: 'u-audit-nurse', roles: ['nurse_operator'], siteId: 'S1' };
const H = 'a'.repeat(64);
const INS = `INSERT INTO clinical_audit_log
  (event_type, actor_id_hash, actor_role, patient_pseudonym, resource_type, resource_id, outcome)
  VALUES ($1, $2, 'clinician', 'P-1', 'scan', $3, 'ok') RETURNING id`;

const INS_NR = INS.replace(' RETURNING id', '');

/** Commits one statement as app_api with session-level app.* settings on a dedicated
 * connection (asRole always rolls back), then resets and discards the connection. */
async function committedAs(p: pg.Pool, rc: RoleCtx, sql: string, params: unknown[]): Promise<void> {
  const c = await p.connect();
  let broken = true;
  try {
    await c.query('SET ROLE app_api');
    await c.query(`SELECT set_config('app.user_id',$1,false), set_config('app.roles',$2,false),
                          set_config('app.site_id',$3,false)`, [rc.userId, rc.roles.join(','), rc.siteId ?? '']);
    await c.query(sql, params); // autocommit
    await c.query('RESET ROLE');
    await c.query('RESET ALL');
    broken = false;
  } finally {
    c.release(broken); // destroy the connection if it could still carry role/settings
  }
}

describe('clinical_audit_log', () => {
  const pool = getTestPool();
  afterAll(async () => { await pool.end(); });

  it('update is a no-op', async () => {
    await asRole(pool, ctx, async (c) => {
      const { rows } = await c.query(INS, ['data_access', H, 'r1']);
      await c.query('UPDATE clinical_audit_log SET outcome = $1 WHERE id = $2', ['changed', rows[0].id]);
      const r = await c.query('SELECT outcome FROM clinical_audit_log WHERE id = $1', [rows[0].id]);
      expect(r.rows[0].outcome).toBe('ok');
    });
  });

  it('delete is a no-op', async () => {
    await asRole(pool, ctx, async (c) => {
      const { rows } = await c.query(INS, ['export', H, 'r2']);
      await c.query('DELETE FROM clinical_audit_log WHERE id = $1', [rows[0].id]);
      const r = await c.query('SELECT 1 FROM clinical_audit_log WHERE id = $1', [rows[0].id]);
      expect(r.rowCount).toBe(1);
    });
  });

  it('accepts the extended event types', async () => {
    await asRole(pool, ctx, async (c) => {
      for (const t of ['device_event', 'view_experimental', 'capture_rejected_post_hoc'])
        await c.query(INS, [t, H, t]);
    });
  });

  it('chain verifies after 50 inserts', async () => {
    await asRole(pool, ctx, async (c) => {
      for (let i = 0; i < 50; i++) await c.query(INS, ['data_access', H, `seq-${i}`]);
      const v = await c.query('SELECT audit_verify_chain() AS v');
      expect(v.rows[0].v).toBeNull();
    });
  });

  it('20 concurrent inserts by a site role (committed, own connections) keep chain valid', async () => {
    const tag = `par-${Date.now()}-`;
    await Promise.all(
      Array.from({ length: 20 }, (_, i) => committedAs(pool, nurse, INS_NR, ['data_access', H, tag + i])),
    );
    const v = await pool.query('SELECT audit_verify_chain() AS v');
    expect(v.rows[0].v).toBeNull();
    const { rows } = await pool.query(
      `SELECT count(*)::int AS n, count(DISTINCT prev_row_hash)::int AS d FROM clinical_audit_log
        WHERE resource_id LIKE $1`,
      [tag + '%'],
    );
    expect(rows[0].n).toBe(20);
    expect(rows[0].d).toBe(20); // no two rows share a predecessor => no fork
  });

  it('nurse SELECT on the audit log returns 0 rows', async () => {
    await committedAs(pool, nurse, INS_NR, ['data_access', H, 'nurse-visible?']);
    await asRole(pool, nurse, async (c) => {
      const r = await c.query('SELECT count(*)::int AS n FROM clinical_audit_log');
      expect(r.rows[0].n).toBe(0);
    });
  });

  it('regulatory_reviewer and admin see rows', async () => {
    await committedAs(pool, nurse, INS_NR, ['data_access', H, 'reviewer-visible']);
    for (const roles of [['regulatory_reviewer'], ['admin']]) {
      await asRole(pool, { userId: 'u-rr', roles }, async (c) => {
        const r = await c.query(`SELECT count(*)::int AS n FROM clinical_audit_log WHERE resource_id='reviewer-visible'`);
        expect(r.rows[0].n).toBeGreaterThan(0);
      });
    }
  });

  it('RLS is enabled and forced on clinical_audit_log', async () => {
    const r = await pool.query(
      `SELECT relrowsecurity AND relforcerowsecurity AS ok FROM pg_class WHERE oid='clinical_audit_log'::regclass`,
    );
    expect(r.rows[0].ok).toBe(true);
  });

  it('chain functions are SECURITY DEFINER with a pinned search_path', async () => {
    const r = await pool.query(
      `SELECT proname, prosecdef, proconfig, pg_get_userbyid(proowner) AS owner FROM pg_proc
        WHERE proname IN ('audit_chain_before_insert','audit_verify_chain') ORDER BY proname`,
    );
    for (const f of r.rows) {
      expect(f.prosecdef, f.proname).toBe(true);
      expect(f.proconfig, f.proname).toEqual(['search_path=pg_catalog, public']);
      expect(f.owner, f.proname).toBe('audit_owner');
    }
    const o = await pool.query(`SELECT rolsuper, rolbypassrls, rolcanlogin FROM pg_roles WHERE rolname='audit_owner'`);
    expect(o.rows[0]).toEqual({ rolsuper: false, rolbypassrls: false, rolcanlogin: false });
  });

  it('insert under REPEATABLE READ raises', async () => {
    const c = await pool.connect();
    try {
      await c.query('BEGIN ISOLATION LEVEL REPEATABLE READ');
      await expect(c.query(INS, ['data_access', H, 'rr'])).rejects.toThrow(/DS_AUD_002/);
    } finally {
      await c.query('ROLLBACK');
      c.release();
    }
  });

  it('caller-supplied occurred_at / prev_row_hash / row_hash are overwritten', async () => {
    await asRole(pool, ctx, async (c) => {
      const r = await c.query(
        `INSERT INTO clinical_audit_log (event_type, actor_id_hash, actor_role, patient_pseudonym, resource_type,
           resource_id, outcome, occurred_at, prev_row_hash, row_hash)
         VALUES ('data_access',$1,'clinician','P-1','scan','forge','ok','2000-01-01T00:00:00Z',$2,$2)
         RETURNING occurred_at, prev_row_hash, row_hash`,
        [H, 'f'.repeat(64)],
      );
      const row = r.rows[0];
      expect(new Date(row.occurred_at).getUTCFullYear()).toBeGreaterThan(2000);
      expect(Math.abs(Date.now() - new Date(row.occurred_at).getTime())).toBeLessThan(60_000);
      expect(row.prev_row_hash).not.toBe('f'.repeat(64));
      expect(row.row_hash).not.toBe('f'.repeat(64));
    });
  });

  it('row_hash is sha256 of the canonical jsonb object of the row', async () => {
    await asRole(pool, ctx, async (c) => {
      const { rows } = await c.query(INS, ['data_access', H, 'canon']);
      const r = await c.query(
        `SELECT row_hash = encode(digest(jsonb_build_object(
            'prev_row_hash', prev_row_hash,
            'occurred_at', to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'event_type', event_type, 'actor_id_hash', actor_id_hash, 'actor_role', actor_role,
            'patient_pseudonym', patient_pseudonym, 'resource_type', resource_type, 'resource_id', resource_id,
            'model_version', model_version, 'risk_band', risk_band, 'inputs_hash', inputs_hash,
            'outputs_hash', outputs_hash, 'outcome', outcome, 'justification', justification)::text,
            'sha256'), 'hex') AS ok
           FROM clinical_audit_log WHERE id=$1`,
        [rows[0].id],
      );
      expect(r.rows[0].ok).toBe(true);
    });
  });

  it('tampering detected', async () => {
    const c = await pool.connect();
    try {
      await c.query('BEGIN');
      const { rows } = await c.query(INS, ['data_access', H, 'tamper']);
      await c.query('INSERT INTO clinical_audit_log (event_type, actor_id_hash, actor_role, patient_pseudonym, resource_type, resource_id, outcome) VALUES ($1,$2,$3,$4,$5,$6,$7)',
        ['data_access', H, 'clinician', 'P-1', 'scan', 'after-tamper', 'ok']);
      await c.query('ALTER TABLE clinical_audit_log DISABLE RULE no_update');
      await c.query("UPDATE clinical_audit_log SET outcome = 'forged' WHERE id = $1", [rows[0].id]);
      await c.query('ALTER TABLE clinical_audit_log ENABLE RULE no_update');
      const v = await c.query('SELECT audit_verify_chain() AS v');
      expect(v.rows[0].v).toBe(rows[0].id);
    } finally {
      await c.query('ROLLBACK');
      c.release();
    }
    const after = await pool.query('SELECT audit_verify_chain() AS v');
    expect(after.rows[0].v).toBeNull();
  });
});
