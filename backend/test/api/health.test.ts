import { Writable } from 'node:stream';
import { describe, it, expect, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../../src/app';
import type { AppDeps } from '../../src/deps';

const deps = { now: () => new Date('2026-10-14T00:00:00Z') } as unknown as AppDeps;

describe('app skeleton', () => {
  let app: FastifyInstance;
  const make = async (extra?: (a: FastifyInstance) => void) => {
    app = buildApp(deps, { logLevel: 'silent' });
    extra?.(app);
    await app.ready();
    return app;
  };
  afterAll(async () => { await app?.close(); });

  it('GET /health -> 200 alive with X-Request-Id', async () => {
    const a = await make();
    const res = await a.inject({ method: 'GET', url: '/health' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ status: 'alive' });
    expect(res.headers['x-request-id']).toBeTruthy();
    await a.close();
  });

  it('uses traceparent trace id as request id', async () => {
    const a = await make();
    const trace = '4bf92f3577b34da6a3ce929d0e0e4736';
    const res = await a.inject({ method: 'GET', url: '/health', headers: { traceparent: `00-${trace}-00f067aa0ba902b7-01` } });
    expect(res.headers['x-request-id']).toBe(trace);
    await a.close();
  });

  it('unknown route -> 404 envelope with request_id', async () => {
    const a = await make();
    const res = await a.inject({ method: 'GET', url: '/v1/nope' });
    expect(res.statusCode).toBe(404);
    const e = res.json().error;
    expect(e.code).toBe('DS_NOT_FOUND');
    expect(e.request_id).toBe(res.headers['x-request-id']);
    expect(e).toHaveProperty('trace_id');
    expect(e).toHaveProperty('detail');
    expect(Date.parse(e.timestamp)).not.toBeNaN();
    await a.close();
  });

  it('thrown Error -> 500 DS_INTERNAL_001 without stack', async () => {
    const a = await make((x) => { x.get('/boom', async () => { throw new Error('secret db failure'); }); });
    const res = await a.inject({ method: 'GET', url: '/boom' });
    expect(res.statusCode).toBe(500);
    expect(res.json().error.code).toBe('DS_INTERNAL_001');
    expect(res.body).not.toContain('secret db failure');
    expect(res.body).not.toContain('at ');
    await a.close();
  });

  it('M2: other Fastify 4xx (415 media type) -> 400 DS_VALIDATION_001; 413 -> 413 DS_VALIDATION_002', async () => {
    const { z } = await import('zod');
    const a = await make((x) => {
      x.post('/v', { schema: { body: z.object({ n: z.number() }).strict() } }, async () => ({}));
    });
    const media = await a.inject({ method: 'POST', url: '/v', headers: { 'content-type': 'text/plain' }, payload: 'n=1' });
    expect(media.statusCode).toBe(400);
    expect(media.json().error.code).toBe('DS_VALIDATION_001');
    const big = await a.inject({
      method: 'POST',
      url: '/v',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({ n: 1, pad: 'x'.repeat(1_100_000) }),
    });
    expect(big.statusCode).toBe(413);
    expect(big.json().error.code).toBe('DS_VALIDATION_002');
    const badJson = await a.inject({ method: 'POST', url: '/v', headers: { 'content-type': 'application/json' }, payload: '{"n":' });
    expect(badJson.statusCode).toBe(400);
    expect(badJson.json().error.code).toBe('DS_VALIDATION_001');
    await a.close();
  });

  it('M3: logger on; 500s are logged with authorization and cookie headers redacted', async () => {
    const lines: string[] = [];
    const stream = new Writable({
      write(chunk, _enc, cb) {
        lines.push(String(chunk));
        cb();
      },
    });
    const a = buildApp(deps, { logStream: stream, logLevel: 'info' });
    a.get('/boom', async () => {
      throw new Error('secret db failure');
    });
    await a.ready();
    const res = await a.inject({
      method: 'GET',
      url: '/boom',
      headers: { authorization: 'Bearer very-secret-token', cookie: 'session=cookie-secret' },
    });
    expect(res.statusCode).toBe(500);
    await a.close();
    const log = lines.join('');
    const errors = lines.map((l) => JSON.parse(l)).filter((l) => l.level === 50);
    expect(errors).toHaveLength(1);
    expect(errors[0].err.message).toBe('secret db failure');
    expect(errors[0].request.headers.authorization).toBe('[REDACTED]');
    expect(errors[0].request.headers.cookie).toBe('[REDACTED]');
    expect(log).not.toContain('very-secret-token');
    expect(log).not.toContain('cookie-secret');
  });

  it('ApiError maps to envelope; zod failure -> 400 DS_VALIDATION_001', async () => {
    const { ApiError } = await import('../../src/errors');
    const { z } = await import('zod');
    const a = await make((x) => {
      x.get('/teapot', async () => { throw new ApiError(418, 'DS_X_001', 'short', { a: 1 }); });
      x.post('/v', { schema: { body: z.object({ n: z.number() }).strict() } }, async () => ({}));
    });
    const r1 = await a.inject({ method: 'GET', url: '/teapot' });
    expect(r1.statusCode).toBe(418);
    expect(r1.json().error).toMatchObject({ code: 'DS_X_001', message: 'short', detail: { a: 1 } });
    const r2 = await a.inject({ method: 'POST', url: '/v', payload: { n: 1, extra: 2 } });
    expect(r2.statusCode).toBe(400);
    expect(r2.json().error.code).toBe('DS_VALIDATION_001');
    await a.close();
  });
});
