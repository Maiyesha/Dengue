import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import pg from 'pg';
import { migrate } from '../db/migrate';
import { getTestPool, connectionConfig } from './pg';

describe('migrate', () => {
  const dbName = 'migrate_test_' + Date.now();
  let client: pg.Client;

  beforeAll(async () => {
    await getTestPool().query(`CREATE DATABASE ${dbName}`);
    client = new pg.Client({ ...connectionConfig(), database: dbName });
    await client.connect();
  });
  afterAll(async () => {
    await client.end();
    await getTestPool().query(`DROP DATABASE ${dbName}`);
    await getTestPool().end();
  });

  it('applies all migrations once', async () => {
    const applied = await migrate(client);
    expect(applied.length).toBeGreaterThanOrEqual(1);
  });

  it('is idempotent', async () => {
    expect(await migrate(client)).toEqual([]);
  });
});
