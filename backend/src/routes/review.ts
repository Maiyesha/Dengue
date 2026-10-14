// Clinician review (WebAuthn step-up) and the gated experimental pulse-rate view.
//
// Review step-up (F8): POST /v1/scans/{id}/review-challenge (clinician, own site, review_pending)
// issues 32 random bytes (base64url) bound to {scan_id, action, reason_code, sha256(note), reviewer},
// stored as sha256 only, 5-minute TTL. POST /v1/scans/{id}/review names it by challenge_id; the
// server consumes it (single use, committed even if the review then fails), checks the binding and
// expiry (else 401 DS_AUTH_003), and verifies the WebAuthn assertion against the stored hash.
// webauthn_assertion_hash = sha256 hex of the canonical JSON of the submitted assertion.
// Experimental view: only rppg_face / rppg_fingertip 'heart_rate', never any other feature, never NaN;
// empty (but audited) for a revoked/excluded scan or a scan whose consent is no longer valid.
import { createHash, randomBytes } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import type { ZodTypeProvider } from 'fastify-type-provider-zod';
import { ApiError } from '../errors';
import { actorOf, requireUser } from '../auth';
import { withRls } from '../db';
import { audit, sha256Hex } from '../audit';
import { idempotent } from '../idempotency';
import { scanConsent } from '../consentGate';

const NOTICE = 'Not validated — do not use for care decisions. Use the monitor value.';
const FLAG = 'show_experimental_at_bedside';
const HIDDEN_STATUSES = new Set(['revoked', 'excluded']);
const notFound = () => new ApiError(404, 'DS_NOT_FOUND', 'Resource not found');

const ACTION_STATUS = {
  confirm: 'reviewed',
  flag: 'flagged',
  request_repeat: 'flagged',
  exclude: 'excluded',
} as const;

/** JSON with object keys sorted recursively; stable input for hashing. */
export function canonicalJson(v: unknown): string {
  if (v === null || typeof v !== 'object') return JSON.stringify(v) ?? 'null';
  if (Array.isArray(v)) return `[${v.map(canonicalJson).join(',')}]`;
  const o = v as Record<string, unknown>;
  return `{${Object.keys(o)
    .filter((k) => o[k] !== undefined)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${canonicalJson(o[k])}`)
    .join(',')}}`;
}

const CHALLENGE_BYTES = 32;
const CHALLENGE_TTL_SEC = 300;

const Action = z.enum(['confirm', 'flag', 'request_repeat', 'exclude']);
const ReasonCode = z.string().min(1).max(100);
const Note = z.string().min(1).max(2000);

const ChallengeBody = z
  .object({ action: Action, reason_code: ReasonCode.optional(), note: Note.optional() })
  .strict();

const ReviewBody = z
  .object({
    challenge_id: z.string().uuid().describe('From POST /v1/scans/{id}/review-challenge; single use, bound to this body'),
    action: Action,
    reason_code: ReasonCode.optional(),
    note: Note.optional(),
    webauthn_assertion: z.record(z.string(), z.unknown()),
  })
  .strict();

const stepUpFailed = (why: string) => new ApiError(401, 'DS_AUTH_003', why);

const Params = z.object({ id: z.string().uuid() });

interface ScanRow {
  id: string;
  site_id: string;
  status: string;
  device_id: string | null;
  patient_id: string | null;
}

async function loadScan(c: pg.PoolClient, id: string, siteId: string | undefined, lock: boolean) {
  const s = (
    await c.query<ScanRow>(
      `SELECT id, site_id, status::text AS status, device_id, patient_id FROM scans WHERE id = $1${lock ? ' FOR UPDATE' : ''}`,
      [id],
    )
  ).rows[0];
  if (!s || s.site_id !== siteId) throw notFound();
  const pseudonym = s.patient_id
    ? ((await c.query<{ pseudonym_id: string }>('SELECT pseudonym_id FROM patients WHERE id = $1', [s.patient_id]))
        .rows[0]?.pseudonym_id ?? 'n/a')
    : 'n/a';
  return { s, pseudonym };
}

export async function reviewRoutes(app: FastifyInstance): Promise<void> {
  const r = app.withTypeProvider<ZodTypeProvider>();

  // Exempt from idempotency: the response carries a fresh nonce that must only exist as a hash.
  r.post(
    '/v1/scans/:id/review-challenge',
    {
      preHandler: [requireUser('clinician')],
      config: { idempotencyExempt: true },
      schema: { params: Params, body: ChallengeBody },
    },
    async (req) => {
      const actor = actorOf(req);
      const b = req.body;
      const raw = randomBytes(CHALLENGE_BYTES);
      const id = await withRls(app.deps.pool, actor, async (c) => {
        const { s } = await loadScan(c, req.params.id, actor.siteId, false);
        if (s.status !== 'review_pending') {
          throw new ApiError(409, 'DS_STATE_001', `Scan in status ${s.status} is not awaiting review`);
        }
        await c.query('DELETE FROM review_challenges WHERE expires_at <= now()');
        return (
          await c.query<{ id: string }>(
            `INSERT INTO review_challenges
               (challenge_hash, scan_id, site_id, reviewer_user_id, action, reason_code, note_sha256, expires_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7, now() + make_interval(secs => $8)) RETURNING id`,
            [
              createHash('sha256').update(raw).digest(),
              s.id,
              s.site_id,
              actor.id,
              b.action,
              b.reason_code ?? null,
              b.note === undefined ? null : sha256Hex(b.note),
              CHALLENGE_TTL_SEC,
            ],
          )
        ).rows[0].id;
      });
      return { challenge_id: id, challenge: raw.toString('base64url'), expires_in: CHALLENGE_TTL_SEC };
    },
  );

  r.post(
    '/v1/scans/:id/review',
    { preHandler: [requireUser('clinician'), idempotent()], schema: { params: Params, body: ReviewBody } },
    async (req, reply) => {
      const actor = actorOf(req);
      const b = req.body;

      // 1. Spend the challenge in its own committed transaction (single use even when the review
      //    fails below). Only the reviewer's own challenges are visible (RLS + WHERE).
      const ch = await withRls(app.deps.pool, actor, async (c) => {
        await loadScan(c, req.params.id, actor.siteId, false); // 404 before spending anything
        return (
          await c.query<{
            scan_id: string; action: string; reason_code: string | null; note_sha256: string | null; hash: string; live: boolean;
          }>(
            `DELETE FROM review_challenges WHERE id = $1 AND reviewer_user_id = $2
             RETURNING scan_id, action, reason_code, note_sha256, encode(challenge_hash, 'hex') AS hash,
                       expires_at > now() AS live`,
            [b.challenge_id, actor.id],
          )
        ).rows[0];
      });
      // 2. The body must match what the challenge was issued for.
      const bound =
        ch !== undefined &&
        ch.live &&
        ch.scan_id === req.params.id &&
        ch.action === b.action &&
        ch.reason_code === (b.reason_code ?? null) &&
        ch.note_sha256 === (b.note === undefined ? null : sha256Hex(b.note));
      if (!bound) throw stepUpFailed('Review challenge is unknown, expired, already used, or does not match this review');
      // 3. The authenticator must have signed exactly that server challenge.
      if (!(await app.deps.webauthn.verify(actor.id, b.webauthn_assertion, ch.hash))) {
        throw stepUpFailed('WebAuthn assertion could not be verified');
      }

      const out = await withRls(app.deps.pool, actor, async (c) => {
        const { s, pseudonym } = await loadScan(c, req.params.id, actor.siteId, true);
        if (s.status !== 'review_pending') {
          throw new ApiError(409, 'DS_STATE_001', `Scan in status ${s.status} is not awaiting review`);
        }

        const target = ACTION_STATUS[b.action];
        const rev = await c.query<{ id: string }>(
          `INSERT INTO scan_reviews (scan_id, reviewer_user_id, action, reason_code, note, webauthn_assertion_hash)
           VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
          [s.id, actor.id, b.action, b.reason_code ?? null, b.note ?? null, sha256Hex(canonicalJson(b.webauthn_assertion))],
        );
        try {
          await c.query(`UPDATE scans SET status = $2 WHERE id = $1`, [s.id, target]);
        } catch (e) {
          // The row is locked and was just read as review_pending, so this is a defensive mapping.
          if (/DS_STATE_001/.test((e as Error).message)) {
            throw new ApiError(409, 'DS_STATE_001', 'Illegal scan status transition');
          }
          throw e;
        }

        const noDevice = b.action === 'request_repeat' && !s.device_id;
        await audit(c, {
          eventType: 'clinician_action',
          actorId: actor.id,
          actorRole: actor.roles[0],
          patientPseudonym: pseudonym,
          resourceType: 'scan',
          resourceId: s.id,
          outcome: `review:${b.action}`,
          justification: noDevice ? 'request_repeat: scan has no device; push notification skipped' : undefined,
        });
        return {
          review_id: rev.rows[0].id,
          scan_id: s.id,
          status: target,
          pseudonym,
          pushDevice: b.action === 'request_repeat' ? s.device_id : null,
        };
      });

      let push: 'sent' | 'failed' | 'skipped' = 'skipped';
      if (out.pushDevice) {
        try {
          await app.deps.push.send(out.pushDevice, { type: 'repeat_requested', scan_id: out.scan_id });
          push = 'sent';
        } catch (err) {
          push = 'failed';
          req.log.error(
            { err, scan_id: out.scan_id, device_id: out.pushDevice, request_id: String(req.id) },
            'repeat_requested push failed',
          );
          // The review is committed, so the response stays 201; record the lost instruction in
          // its own transaction. If this audit also fails, still do not fail the response.
          try {
            await withRls(app.deps.pool, actor, (c) =>
              audit(c, {
                eventType: 'device_event',
                actorId: actor.id,
                actorRole: actor.roles[0],
                patientPseudonym: out.pseudonym,
                resourceType: 'scan',
                resourceId: out.scan_id,
                outcome: 'push:repeat_requested_failed',
              }),
            );
          } catch (aerr) {
            req.log.error({ err: aerr, scan_id: out.scan_id }, 'push failure audit could not be written');
          }
        }
      }
      return reply.status(201).send({ review_id: out.review_id, scan_id: out.scan_id, status: out.status, push });
    },
  );

  r.get(
    '/v1/scans/:id/experimental',
    { preHandler: [requireUser('nurse_operator', 'clinician')], schema: { params: Params } },
    async (req) => {
      const actor = actorOf(req);
      return withRls(app.deps.pool, actor, async (c) => {
        const { s, pseudonym } = await loadScan(c, req.params.id, actor.siteId, false);
        const flag = await c.query<{ enabled: boolean }>(
          'SELECT enabled FROM site_protocol_flags WHERE site_id = $1 AND flag = $2',
          [s.site_id, FLAG],
        );
        if (flag.rows[0]?.enabled !== true) return { enabled: false, items: [] };

        // Nothing is shown for a revoked/excluded scan or when consent is no longer valid (same
        // gate as capture); the view is still audited because the flag is on.
        const gate = await scanConsent(c, s.id);
        const hidden = HIDDEN_STATUSES.has(s.status) || !gate || gate.block !== null;
        const f = hidden
          ? { rows: [] as Array<{ domain: string; value: string }> }
          : await c.query<{ domain: string; value: string }>(
              `SELECT DISTINCT ON (domain) domain, value::text AS value
                 FROM features
                WHERE scan_id = $1 AND name = 'heart_rate' AND domain IN ('rppg_face','rppg_fingertip')
                  AND value IS NOT NULL AND value <> 'NaN'
                ORDER BY domain, feature_availability_timestamp DESC, pipeline_version DESC`,
              [s.id],
            );
        await audit(c, {
          eventType: 'view_experimental',
          actorId: actor.id,
          actorRole: actor.roles[0],
          patientPseudonym: pseudonym,
          resourceType: 'scan',
          resourceId: s.id,
          outcome: 'experimental:view',
        });
        return {
          enabled: true,
          items: f.rows.map((x) => ({
            domain: x.domain,
            pulse_rate_bpm: Math.round(Number(x.value)),
            label: 'EXPERIMENTAL' as const,
            notice: NOTICE,
          })),
        };
      });
    },
  );
}
