import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { migrate } from '../db/migrate';

const PORT = 54329;
const TEST_DB = 'dengue_test';
const DATA_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '.embedded-pg');

export function connectionConfig(): pg.ClientConfig {
  return { host: '127.0.0.1', port: PORT, user: 'postgres', password: 'postgres', database: 'postgres' };
}

let pool: pg.Pool | undefined;

/** Superuser pool to the freshly migrated test DB. */
export function getTestPool(): pg.Pool {
  pool ??= new pg.Pool({ ...connectionConfig(), database: TEST_DB, max: 30 });
  return pool;
}

export interface RoleCtx {
  userId: string;
  roles: string[];
  siteId?: string;
  deidentify?: boolean;
}

/** Runs fn as app_api with app.* settings in a transaction that is always rolled back. */
export async function asRole<T>(
  p: pg.Pool,
  ctx: RoleCtx,
  fn: (c: pg.PoolClient) => Promise<T>,
): Promise<T> {
  const c = await p.connect();
  try {
    await c.query('BEGIN');
    await c.query('SET LOCAL ROLE app_api');
    const settings: Array<[string, string]> = [
      ['app.user_id', ctx.userId],
      ['app.roles', ctx.roles.join(',')],
    ];
    if (ctx.siteId !== undefined) settings.push(['app.site_id', ctx.siteId]);
    if (ctx.deidentify !== undefined) settings.push(['app.deidentify', String(ctx.deidentify)]);
    for (const [k, v] of settings) await c.query('SELECT set_config($1, $2, true)', [k, v]);
    return await fn(c);
  } finally {
    try {
      await c.query('ROLLBACK');
    } finally {
      c.release();
    }
  }
}

// ---- Vitest globalSetup ----
export default async function setup() {
  const { default: EmbeddedPostgres } = await import('embedded-postgres');
  fs.rmSync(DATA_DIR, { recursive: true, force: true }); // leftover from a crashed run
  const server = new EmbeddedPostgres({
    databaseDir: DATA_DIR,
    user: 'postgres',
    password: 'postgres',
    port: PORT,
    persistent: false,
  });
  await server.initialise();
  await server.start();
  const admin = new pg.Client(connectionConfig());
  await admin.connect();
  await admin.query(`CREATE DATABASE ${TEST_DB}`);
  await admin.end();
  const c = new pg.Client({ ...connectionConfig(), database: TEST_DB });
  await c.connect();
  await migrate(c);
  await c.end();
  return async () => {
    await server.stop();
    fs.rmSync(DATA_DIR, { recursive: true, force: true });
  };
}
