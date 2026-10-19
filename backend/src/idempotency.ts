// Idempotency for POST routes.
//
// Opt-in (every POST under /v1 must do this; a boot-time check enforces it):
//   app.register(idempotencyPlugin)      // once, in buildApp BEFORE any route (not encapsulated)
//   app.post('/v1/x', { preHandler: [requireUser(...), idempotent()] }, handler)
// `idempotent()` MUST come after the auth guard (keys are scoped to the authenticated actor id).
// A POST that is deliberately exempt sets `config: { idempotencyExempt: true }`.
//
// Protocol: Idempotency-Key header (UUID v4), else 400 DS_IDEMPOTENCY_002.
//   - first request inserts a claim row (status_code NULL) ON CONFLICT DO NOTHING and runs the handler;
//     the response (status + JSON body) is stored in onSend when it is 2xx or 400/404/409/422/451;
//     any other status (401, 403, 408, 429, 5xx, ...) releases the claim so a retry re-runs; a handler
//     may also release a stored-class error it knows to be retryable (req.idempotencyRelease).
//   - same key + same payload hash -> stored response replayed (waits up to 5 s, polling every 100 ms,
//     while the first request is in flight; if still in flight afterwards: 409 DS_IDEMPOTENCY_003).
//   - same key + different payload -> 409 DS_IDEMPOTENCY_001.
//   - rows older than 24 h (and claims in flight for > 5 min, i.e. a crashed worker) are treated as absent.
import { createHash, randomUUID } from 'node:crypto';
import type { FastifyInstance, FastifyReply, FastifyRequest, preHandlerAsyncHookHandler } from 'fastify';
import { actorOf } from './auth';
import { withRls } from './db';
import { ApiError } from './errors';

const KEY_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const WAIT_MS = 5000;
const POLL_MS = 100;
const TTL = '24 hours';
const STALE_CLAIM = '5 minutes';

interface Claim {
  actorId: string;
  route: string;
  key: string;
  owner: string;
}

declare module 'fastify' {
  interface FastifyRequest {
    idempotencyClaim?: Claim;
    /** Set by a handler for a retryable error that must not be stored (e.g. 409 DS_UPLOAD_005). */
    idempotencyRelease?: boolean;
  }
  interface FastifyContextConfig {
    idempotencyExempt?: boolean;
  }
}

export function canonicalJson(v: unknown): string {
  if (v === undefined) return 'null';
  if (v === null || typeof v !== 'object') return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map(canonicalJson).join(',')}]`;
  const o = v as Record<string, unknown>;
  const parts = Object.keys(o)
    .sort()
    .filter((k) => o[k] !== undefined)
    .map((k) => `${JSON.stringify(k)}:${canonicalJson(o[k])}`);
  return `{${parts.join(',')}}`;
}

export const payloadHash = (body: unknown) => createHash('sha256').update(canonicalJson(body)).digest('hex');

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

interface Row {
  payload_hash: string;
  status_code: number | null;
  response: unknown;
  expired: boolean;
}

type Outcome =
  | { kind: 'claimed' | 'retry' | 'mismatch' | 'inflight' }
  | { kind: 'replay'; status: number; body: unknown };

const EXPIRED_SQL = `(created_at < now() - interval '${TTL}'
  OR (status_code IS NULL AND created_at < now() - interval '${STALE_CLAIM}'))`;

/** preHandler: claim the key or replay the stored response. Place after the auth guard. */
export function idempotent(): preHandlerAsyncHookHandler {
  const handler: preHandlerAsyncHookHandler = async function (this: FastifyInstance, req: FastifyRequest, reply: FastifyReply) {
    const actor = actorOf(req);
    const key = req.headers['idempotency-key'];
    if (typeof key !== 'string' || !KEY_RE.test(key)) {
      throw new ApiError(400, 'DS_IDEMPOTENCY_002', 'Idempotency-Key header (UUID v4) is required');
    }
    const route = req.routeOptions.url ?? req.url;
    // Scope = path params + query + body, so the same key on /patients/A/x and /patients/B/x conflicts.
    const hash = payloadHash({ params: req.params ?? {}, query: req.query ?? {}, body: req.body ?? null });
    const owner = randomUUID();
    const pool = this.deps.pool;
    const deadline = Date.now() + WAIT_MS;

    for (;;) {
      const outcome: Outcome = await withRls(pool, actor, async (c): Promise<Outcome> => {
        const ins = await c.query(
          `INSERT INTO idempotency_keys(actor_id, method, route, key, payload_hash, owner)
           VALUES ($1, 'POST', $2, $3, $4, $5) ON CONFLICT DO NOTHING`,
          [actor.id, route, key, hash, owner],
        );
        if (ins.rowCount === 1) return { kind: 'claimed' };
        const sel = await c.query<Row>(
          `SELECT payload_hash, status_code, response, ${EXPIRED_SQL} AS expired
             FROM idempotency_keys
            WHERE actor_id = $1 AND method = 'POST' AND route = $2 AND key = $3`,
          [actor.id, route, key],
        );
        const row = sel.rows[0];
        if (!row) return { kind: 'retry' }; // released between insert and select
        if (row.expired) {
          // Atomic takeover: only one concurrent request can win the reset.
          const up = await c.query(
            `UPDATE idempotency_keys
                SET payload_hash = $4, owner = $5, status_code = NULL, response = NULL, created_at = now()
              WHERE actor_id = $1 AND method = 'POST' AND route = $2 AND key = $3 AND ${EXPIRED_SQL}`,
            [actor.id, route, key, hash, owner],
          );
          return { kind: up.rowCount === 1 ? 'claimed' : 'retry' };
        }
        if (row.payload_hash !== hash) return { kind: 'mismatch' };
        if (row.status_code === null) return { kind: 'inflight' };
        return { kind: 'replay', status: row.status_code, body: row.response };
      });

      if (outcome.kind === 'claimed') {
        req.idempotencyClaim = { actorId: actor.id, route, key, owner };
        return;
      }
      if (outcome.kind === 'mismatch') {
        throw new ApiError(409, 'DS_IDEMPOTENCY_001', 'Idempotency-Key was already used with a different payload');
      }
      if (outcome.kind === 'replay') {
        reply.header('Idempotent-Replayed', 'true').status(outcome.status);
        return reply.send(outcome.body === null ? undefined : outcome.body);
      }
      if (outcome.kind === 'inflight') {
        if (Date.now() >= deadline) {
          throw new ApiError(409, 'DS_IDEMPOTENCY_003', 'A request with this Idempotency-Key is still in progress');
        }
        await sleep(POLL_MS);
      }
    }
  };
  (handler as unknown as { isIdempotency: boolean }).isIdempotency = true;
  return handler;
}

/**
 * Responses that are a deterministic answer to the payload and are stored for replay: every 2xx,
 * and 400 / 404 / 409 / 422 / 451. Everything else (401, 403 incl. DS_AUD_001, 408, 429, 5xx, ...)
 * is transient or about the credentials, so the claim is released and a retry re-runs the handler.
 */
const STORED_ERRORS = new Set([400, 404, 409, 422, 451]);
export const isStorable = (status: number) => (status >= 200 && status < 300) || STORED_ERRORS.has(status);

const hasMarker = (h: unknown): boolean =>
  Array.isArray(h) ? h.some(hasMarker) : typeof h === 'function' && (h as { isIdempotency?: boolean }).isIdempotency === true;

/** Not encapsulated (skip-override), so its hooks apply to every route registered after it. */
export async function idempotencyPlugin(app: FastifyInstance): Promise<void> {
  // Boot-time guard: every POST under /v1 must use idempotent() (or be explicitly exempt).
  app.addHook('onRoute', (opts) => {
    const methods = Array.isArray(opts.method) ? opts.method : [opts.method];
    if (!methods.includes('POST') || !opts.url.startsWith('/v1/')) return;
    if (opts.config?.idempotencyExempt || hasMarker(opts.preHandler)) return;
    throw new Error(`POST ${opts.url} must use idempotent() in preHandler (or set config.idempotencyExempt)`);
  });

  // Store the response of a claimed request when it is a final answer for this payload; release
  // the claim otherwise so the client can retry with the same key.
  app.addHook('onSend', async (req, reply, payload) => {
    const claim = req.idempotencyClaim;
    if (!claim) return payload;
    req.idempotencyClaim = undefined;
    const status = reply.statusCode;
    // Crash window: the response is stored AFTER the handler's own transaction commits, so a crash
    // (or a store failure) between the two leaves the claim in flight; a retry then waits and the
    // claim is taken over once stale (5 min), re-running the handler (later routes rely on natural
    // keys to stay duplicate-free). A store failure must never turn a success into a 500.
    // Only the claim owner may write: a stale writer cannot clobber a newer claim.
    try {
      await withRls(app.deps.pool, actorOf(req), async (c) => {
        const where = `actor_id = $1 AND method = 'POST' AND route = $2 AND key = $3 AND owner = $4`;
        const args = [claim.actorId, claim.route, claim.key, claim.owner];
        if (!isStorable(status) || req.idempotencyRelease) {
          await c.query(`DELETE FROM idempotency_keys WHERE ${where} AND status_code IS NULL`, args);
          return;
        }
        let body: string | null = null;
        if (typeof payload === 'string' && payload !== '') {
          try {
            body = JSON.stringify(JSON.parse(payload));
          } catch {
            body = null;
          }
        }
        await c.query(
          `UPDATE idempotency_keys SET status_code = $5, response = $6::jsonb WHERE ${where} AND status_code IS NULL`,
          [...args, status, body],
        );
      });
    } catch (err) {
      req.log.error({ err }, 'idempotency: failed to store response; claim left for stale takeover');
    }
    return payload;
  });
}
(idempotencyPlugin as unknown as Record<symbol, boolean>)[Symbol.for('skip-override')] = true;
