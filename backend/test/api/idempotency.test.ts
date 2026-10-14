import { randomUUID } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { requireUser } from '../../src/auth';
import { idempotent, idempotencyPlugin } from '../../src/idempotency';
import { getTestPool } from '../pg';
import { seedFixtures, clearFixtures, SITE_A } from '../fixtures';
import { buildTestApp, tokenFor, bearer } from './helpers';

const pool = getTestPool();
let app: FastifyInstance;
let calls = 0;
let failNext = false;
let delays: number[] = [];

const post = async (key: string | undefined, payload: object, token?: string) =>
  app.inject({
    method: 'POST',
    url: '/v1/t/idem',
    headers: {
      ...bearer(token ?? (await tokenFor('nurse_operator', SITE_A))),
      ...(key ? { 'idempotency-key': key } : {}),
    },
    payload,
  });

beforeAll(async () => {
  await seedFixtures(pool);
  ({ app } = await buildTestApp((a) => {
    a.register(idempotencyPlugin);
    a.after(() => {
      a.post('/v1/t/idem', { preHandler: [requireUser('nurse_operator'), idempotent()] }, async (req, reply) => {
        const n = ++calls;
        await new Promise((r) => setTimeout(r, delays.shift() ?? 300));
        if (failNext) {
          failNext = false;
          throw new Error('boom');
        }
        return reply.status(201).send({ n, echo: req.body });
      });
      a.post('/v1/t/p/:id', { preHandler: [requireUser('nurse_operator'), idempotent()] }, async (req) => ({
        id: (req.params as { id: string }).id,
      }));
    });
  }));
});

afterAll(async () => {
  await app.close();
  await pool.query(`DELETE FROM idempotency_keys`);
  await clearFixtures(pool);
  await pool.end();
});

describe('idempotency', () => {
  it('missing or malformed key -> 400 DS_IDEMPOTENCY_002', async () => {
    for (const k of [undefined, 'not-a-uuid']) {
      const r = await post(k, { a: 1 });
      expect(r.statusCode).toBe(400);
      expect(r.json().error.code).toBe('DS_IDEMPOTENCY_002');
    }
  });

  it('replay with same payload -> same status and body, handler called once', async () => {
    const key = randomUUID();
    calls = 0;
    const a = await post(key, { x: 1, y: 2 });
    const b = await post(key, { y: 2, x: 1 }); // key order does not matter
    expect(a.statusCode).toBe(201);
    expect(b.statusCode).toBe(201);
    expect(b.json()).toEqual(a.json());
    expect(calls).toBe(1);
  });

  it('same key, different payload -> 409 DS_IDEMPOTENCY_001', async () => {
    const key = randomUUID();
    await post(key, { x: 1 });
    const r = await post(key, { x: 2 });
    expect(r.statusCode).toBe(409);
    expect(r.json().error.code).toBe('DS_IDEMPOTENCY_001');
  });

  it('parallel identical requests -> handler called once, identical responses', async () => {
    const key = randomUUID();
    calls = 0;
    const [a, b] = await Promise.all([post(key, { p: 1 }), post(key, { p: 1 })]);
    expect(calls).toBe(1);
    expect(a.statusCode).toBe(201);
    expect(b.statusCode).toBe(201);
    expect(b.json()).toEqual(a.json());
  });

  it('key older than 24h is treated as new', async () => {
    const key = randomUUID();
    calls = 0;
    await post(key, { x: 1 });
    await pool.query(`UPDATE idempotency_keys SET created_at = now() - interval '25 hours' WHERE key = $1`, [key]);
    const r = await post(key, { x: 2 }); // different payload is fine: the old row is absent
    expect(r.statusCode).toBe(201);
    expect(calls).toBe(2);
    expect(r.json().echo).toEqual({ x: 2 });
  });

  it('keys are scoped per actor', async () => {
    const key = randomUUID();
    calls = 0;
    await post(key, { x: 1 });
    await post(key, { x: 1 }, await tokenFor('nurse_operator', SITE_A, { sub: 'someone-else' }));
    expect(calls).toBe(2);
  });

  it('5xx releases the claim so a retry re-runs the handler', async () => {
    const key = randomUUID();
    calls = 0;
    failNext = true;
    const a = await post(key, { x: 1 });
    expect(a.statusCode).toBe(500);
    const b = await post(key, { x: 1 });
    expect(b.statusCode).toBe(201);
    expect(calls).toBe(2);
  });

  it('same key and body on a different path param -> 409, never a replay', async () => {
    const key = randomUUID();
    const tok = await tokenFor('nurse_operator', SITE_A);
    const go = (id: string) =>
      app.inject({ method: 'POST', url: `/v1/t/p/${id}`, headers: { ...bearer(tok), 'idempotency-key': key }, payload: {} });
    const a = await go('A');
    expect(a.json().id).toBe('A');
    const b = await go('B');
    expect(b.statusCode).toBe(409);
    expect(b.json().error.code).toBe('DS_IDEMPOTENCY_001');
  });

  it('stale takeover: old writer cannot overwrite the new owner', async () => {
    const key = randomUUID();
    calls = 0;
    delays = [800, 0];
    const slow = post(key, { s: 1 });
    await new Promise((r) => setTimeout(r, 250));
    await pool.query(`UPDATE idempotency_keys SET created_at = now() - interval '10 minutes' WHERE key = $1`, [key]);
    const fast = await post(key, { s: 1 });
    expect(fast.statusCode).toBe(201);
    expect(fast.json().n).toBe(2);
    const old = await slow;
    expect(old.json().n).toBe(1); // the slow caller still got its own response
    const { rows } = await pool.query(`SELECT status_code, response FROM idempotency_keys WHERE key = $1`, [key]);
    expect(rows[0].response.n).toBe(2);
    const again = await post(key, { s: 1 });
    expect(again.json().n).toBe(2);
    expect(calls).toBe(2);
  });

  it('store failure keeps the original 2xx', async () => {
    const real = pool;
    const flaky = {
      connect: async () => {
        const c = await real.connect();
        const q = c.query.bind(c) as (...a: unknown[]) => Promise<unknown>;
        (c as unknown as { query: unknown }).query = (sql: unknown, ...rest: unknown[]) =>
          typeof sql === 'string' && sql.startsWith('UPDATE idempotency_keys SET status_code')
            ? Promise.reject(new Error('store down'))
            : q(sql, ...rest);
        return c;
      },
    };
    const { app: app2 } = await buildTestApp(
      (a) => {
        a.register(idempotencyPlugin);
        a.after(() => {
          a.post('/v1/t/ok', { preHandler: [requireUser('nurse_operator'), idempotent()] }, async (_r, reply) =>
            reply.status(201).send({ ok: true }),
          );
        });
      },
      { pool: flaky as unknown as typeof real },
    );
    const key = randomUUID();
    const r = await app2.inject({
      method: 'POST',
      url: '/v1/t/ok',
      headers: { ...bearer(await tokenFor('nurse_operator', SITE_A)), 'idempotency-key': key },
      payload: {},
    });
    expect(r.statusCode).toBe(201);
    expect(r.json()).toEqual({ ok: true });
    const { rows } = await pool.query(`SELECT status_code FROM idempotency_keys WHERE key = $1`, [key]);
    expect(rows[0].status_code).toBeNull(); // claim left for stale takeover
    await app2.close();
  });

  it('boot guard rejects a /v1 POST without idempotent()', async () => {
    await expect(
      buildTestApp((a) => {
        a.register(idempotencyPlugin);
        a.register(async (s) => {
          s.post('/v1/t/bare', { preHandler: requireUser('nurse_operator') }, async () => ({}));
        });
      }),
    ).rejects.toThrow(/idempotent/);
  });
});
