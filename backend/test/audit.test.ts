import { describe, it, expect } from 'vitest';
import { getTestPool, asRole } from './pg';

const ctx = { userId: 'u-audit', roles: ['clinician'], siteId: 'S1' };
const H = 'a'.repeat(64);
const INS = `INSERT INTO clinical_audit_log
  (event_type, actor_id_hash, actor_role, patient_pseudonym, resource_type, resource_id, outcome)
  VALUES ($1, $2, 'clinician', 'P-1', 'scan', $3, 'ok') RETURNING id`;

describe('clinical_audit_log', () => {
  const pool = getTestPool();

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

  it('20 concurrent inserts keep chain valid', async () => {
    await Promise.all(
      Array.from({ length: 20 }, (_, i) => pool.query(INS, ['data_access', H, `par-${i}`])),
    );
    const v = await pool.query('SELECT audit_verify_chain() AS v');
    expect(v.rows[0].v).toBeNull();
    const { rows } = await pool.query(
      `SELECT count(*)::int AS n, count(DISTINCT prev_row_hash)::int AS d FROM clinical_audit_log
        WHERE resource_id LIKE 'par-%'`,
    );
    expect(rows[0].n).toBe(20);
    expect(rows[0].d).toBe(20); // no two rows share a predecessor => no fork
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
