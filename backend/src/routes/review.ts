// Clinician review (WebAuthn step-up) and the gated experimental pulse-rate view.
//
// Review challenge = sha256 hex of canonical JSON {scan_id, action, reason_code|null, note|null}.
// webauthn_assertion_hash = sha256 hex of the canonical JSON of the submitted assertion.
// Experimental view: only rppg_face / rppg_fingertip 'heart_rate', never any other feature.
import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import type { ZodTypeProvider } from 'fastify-type-provider-zod';
import { ApiError } from '../errors';
import { actorOf, requireUser } from '../auth';
import { withRls } from '../db';
import { audit, sha256Hex } from '../audit';
import { idempotent } from '../idempotency';

const NOTICE = 'Not validated — do not use for care decisions. Use the monitor value.';
const FLAG = 'show_experimental_at_bedside';
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

export const reviewChallenge = (scanId: string, action: string, reason: string | null, note: string | null) =>
  sha256Hex(canonicalJson({ scan_id: scanId, action, reason_code: reason, note }));

const ReviewBody = z
  .object({
    action: z.enum(['confirm', 'flag', 'request_repeat', 'exclude']),
    reason_code: z.string().min(1).max(100).optional(),
    note: z.string().min(1).max(2000).optional(),
    webauthn_assertion: z.record(z.string(), z.unknown()),
  })
  .strict();

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

  r.post(
    '/v1/scans/:id/review',
    { preHandler: [requireUser('clinician'), idempotent()], schema: { params: Params, body: ReviewBody } },
    async (req, reply) => {
      const actor = actorOf(req);
      const b = req.body;
      const out = await withRls(app.deps.pool, actor, async (c) => {
        const { s, pseudonym } = await loadScan(c, req.params.id, actor.siteId, true);

        const challenge = reviewChallenge(s.id, b.action, b.reason_code ?? null, b.note ?? null);
        if (!(await app.deps.webauthn.verify(actor.id, b.webauthn_assertion, challenge))) {
          throw new ApiError(401, 'DS_AUTH_003', 'WebAuthn assertion could not be verified');
        }
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

        const f = await c.query<{ domain: string; value: string }>(
          `SELECT DISTINCT ON (domain) domain, value::text AS value
             FROM features
            WHERE scan_id = $1 AND name = 'heart_rate' AND domain IN ('rppg_face','rppg_fingertip')
              AND value IS NOT NULL
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
