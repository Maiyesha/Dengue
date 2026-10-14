// Per-request RLS transaction. Every API query runs inside withRls().
import type pg from 'pg';
import { USER_ROLES, type Actor } from './auth';

// Evaluated lazily (auth.ts and db.ts import each other).
const isRlsRole = (r: string) => r === 'device' || (USER_ROLES as readonly string[]).includes(r);

/**
 * Actors are sometimes hand-built (e.g. the server-internal system_agent actor of the device
 * routes), so the roles are re-checked here: each must be a known app role (the 7 app_role
 * values or 'device') and must not contain ',' (app.roles is comma-joined; a comma would smuggle
 * in extra roles). An empty role list is also refused.
 */
function assertRlsRoles(roles: readonly unknown[]): void {
  if (!Array.isArray(roles) || roles.length === 0) throw new Error('withRls: actor has no roles');
  for (const r of roles) {
    if (typeof r !== 'string' || r.includes(',') || !isRlsRole(r)) {
      throw new Error(`withRls: refusing actor with invalid role ${JSON.stringify(r)}`);
    }
  }
}

/**
 * Runs fn in one READ COMMITTED transaction as role app_api with the actor's app.* settings
 * (transaction-local, so nothing leaks to the next user of the pooled connection).
 * Commits on success; rolls back and rethrows on any error.
 *
 * READ COMMITTED is required: the clinical_audit_log chain trigger rejects other isolation
 * levels (DS_AUD_002). It is set explicitly so a server-level default cannot change it.
 * The pool's login role must not be a superuser in production; SET LOCAL ROLE app_api drops
 * to app_api's privileges (NOBYPASSRLS) for the whole transaction either way.
 */
export async function withRls<T>(
  pool: pg.Pool,
  actor: Actor,
  fn: (c: pg.PoolClient) => Promise<T>,
): Promise<T> {
  assertRlsRoles(actor.roles);
  const c = await pool.connect();
  let broken: Error | undefined;
  try {
    await c.query('BEGIN ISOLATION LEVEL READ COMMITTED');
    await c.query('SET LOCAL ROLE app_api');
    await c.query(
      `SELECT set_config('app.user_id', $1, true), set_config('app.roles', $2, true),
              set_config('app.site_id', $3, true), set_config('app.deidentify', $4, true)`,
      [actor.id, actor.roles.join(','), actor.siteId ?? '', String(actor.deidentify)],
    );
    const result = await fn(c);
    const commit = await c.query('COMMIT');
    // COMMIT of an aborted transaction (fn swallowed a DB error) is reported as ROLLBACK.
    if (commit.command !== 'COMMIT') throw new Error('withRls: transaction was aborted and rolled back');
    return result;
  } catch (e) {
    try {
      await c.query('ROLLBACK');
    } catch (re) {
      broken = re as Error; // connection unusable; destroy it
    }
    throw e;
  } finally {
    c.release(broken);
  }
}
