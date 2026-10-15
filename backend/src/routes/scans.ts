// Scan sessions: creation (online or offline upload), read-back, and per-step recapture.
//
// POST /v1/scans rule order (inside one RLS transaction, serialised per patient by an advisory lock):
//   0. patient must be visible and on the caller's site, else 404
//   1. same client_session_id already stored for this patient -> 200 with the existing scan, after a
//      consent re-check (scan_consent_rejection): a block is 451 plus a committed
//      capture_rejected_post_hoc audit row
//   2. consent gate (451 DS_REG_001 / DS_REG_002); for offline=true a capture_rejected_post_hoc
//      audit row is committed even though the request fails (no scan row is ever written)
//   3. a non-revoked scan of the patient within 30 min either side of captured_at -> 409 DS_SCAN_001
//   4. insert scan + device attempts, audit clinician_action 'scan:create' -> 201
//
// Steps exhausted (attempt 3 used) on recapture are recorded in scans.metadata.unable_to_acquire:
// scan_step_attempts is insert-only for app_api and attempt is CHECKed to 1..3.
import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import type { ZodTypeProvider } from 'fastify-type-provider-zod';
import { ApiError } from '../errors';
import { actorOf, requireUser, requireUserOrDevice, type Actor } from '../auth';
import { withRls } from '../db';
import { audit } from '../audit';
import { idempotent } from '../idempotency';
import {
  CONSENT_MESSAGES, auditPostHocRejection, consentRejection, scanConsent, type ConsentRejection,
} from '../consentGate';

const MAX_ATTEMPTS = 3;
const DUPLICATE_WINDOW_SEC = 30 * 60;
const CORE_STEPS = new Set(['neutral_face', 'fingertip_ppg']);
const RECAPTURABLE = new Set(['capture_pending', 'quality_failed']);

const notFound = () => new ApiError(404, 'DS_NOT_FOUND', 'Resource not found');
const invalid = (message: string, detail: object = {}) => new ApiError(400, 'DS_VALIDATION_001', message, detail);

const CaptureStep = z.enum(['neutral_face', 'fingertip_ppg', 'ocular_capture', 'dorsal_tongue']);
type CaptureStepT = z.infer<typeof CaptureStep>;
const ReasonCode = z.string().min(1).max(64);

/** doc 03 ContextualMetadata + capture-rig fields. */
const CaptureMetadata = z
  .object({
    camera_model: z.string().min(1).max(128),
    frame_rate: z.number().min(20).max(240),
    resolution: z.string().regex(/^[0-9]+x[0-9]+$/),
    exposure: z.number(),
    distance_cm: z.number().min(20).max(80),
    angle_deg: z.number().min(-15).max(15),
    lighting_lux: z.number().min(200),
    ambient_temp_c: z.number().optional(),
    ambient_humidity_pct: z.number().min(0).max(100).optional(),
    mount: z.enum(['handheld', 'holder']),
    lighting_type: z.string().min(1).max(64),
    exposure_duration_ms: z.number().positive(),
  })
  .strict();

const DeviceAttempt = z
  .object({
    step: CaptureStep,
    attempt: z.number().int().min(1).max(MAX_ATTEMPTS),
    device_verdict: z.enum(['ACCEPT', 'RECAPTURE', 'UNABLE_TO_ACQUIRE']),
    reason_codes: z.array(ReasonCode).max(32),
  })
  .strict();

const uniqueSteps = (a: string[]) => new Set(a).size === a.length;

const ScanBody = z
  .object({
    client_session_id: z.string().uuid(),
    patient_id: z.string().uuid(),
    captured_at: z.string().datetime({ offset: true }),
    offline: z.boolean(),
    protocol_version: z.string().min(1).max(64),
    capture_steps: z
      .array(CaptureStep)
      .min(1)
      .max(4)
      .refine(uniqueSteps, 'capture_steps must be unique')
      .refine((a) => [...CORE_STEPS].every((c) => a.includes(c as CaptureStepT)), 'capture_steps must include both core steps'),
    device_attempts: z.array(DeviceAttempt).max(12),
    metadata: CaptureMetadata,
  })
  .strict()
  .superRefine((b, ctx) => {
    const seen = new Set<string>();
    b.device_attempts.forEach((a, i) => {
      if (!b.capture_steps.includes(a.step)) {
        ctx.addIssue({ code: 'custom', path: ['device_attempts', i, 'step'], message: 'step is not in capture_steps' });
      }
      const k = `${a.step}#${a.attempt}`;
      if (seen.has(k)) {
        ctx.addIssue({ code: 'custom', path: ['device_attempts', i], message: 'duplicate step/attempt' });
      }
      seen.add(k);
    });
  });

const RecaptureBody = z
  .object({
    steps: z.array(CaptureStep).min(1).max(4).refine(uniqueSteps, 'steps must be unique'),
    trigger_reason_code: ReasonCode,
  })
  .strict();

const IdParams = z.object({ id: z.string().uuid() });

interface ScanRow {
  id: string;
  status: string;
  client_session_id: string;
  patient_id: string;
}

const scanRef = (s: ScanRow) => ({ id: s.id, status: s.status, client_session_id: s.client_session_id });

/** Full read-back: attempts ordered by step (enum order) then attempt. */
async function scanView(c: pg.PoolClient, id: string, status: string, metadata: { capture_steps?: string[] }) {
  const steps = (
    await c.query<{ step: string; attempt: number; device_verdict: string; server_verdict: string | null; reason_codes: string[] | null }>(
      `SELECT step::text AS step, attempt, device_verdict, server_verdict, reason_codes
         FROM scan_step_attempts WHERE scan_id = $1 ORDER BY step, attempt`,
      [id],
    )
  ).rows.map((r) => ({ ...r, reason_codes: r.reason_codes ?? [] }));
  const highest = new Map<string, number>();
  for (const s of metadata.capture_steps ?? []) highest.set(s, 0);
  for (const s of steps) highest.set(s.step, Math.max(highest.get(s.step) ?? 0, s.attempt));
  const recaptures_remaining: Record<string, number> = {};
  for (const [step, n] of highest) recaptures_remaining[step] = Math.max(0, MAX_ATTEMPTS - n);
  return { id, status, steps, recaptures_remaining };
}

/** Audit actor_role: the role that satisfied the route guard (M1). */
const actorRole = (a: Actor) => a.role;

type CreateOutcome =
  | { kind: 'created' | 'existing'; scan: ScanRow }
  | { kind: 'consent'; code: ConsentRejection };

type RecaptureOutcome =
  | { kind: 'ok'; view: Awaited<ReturnType<typeof scanView>> }
  | { kind: 'exhausted'; steps: CaptureStepT[]; recaptured: CaptureStepT[]; status: string }
  | { kind: 'consent'; code: ConsentRejection };

export async function scanRoutes(app: FastifyInstance): Promise<void> {
  const r = app.withTypeProvider<ZodTypeProvider>();
  const site = requireUser('nurse_operator', 'clinician');

  r.post(
    '/v1/scans',
    { preHandler: [site, idempotent()], schema: { body: ScanBody } },
    async (req, reply) => {
      const actor = actorOf(req);
      const b = req.body;
      const existingFor = async (c: pg.PoolClient): Promise<ScanRow | null> => {
        const s = (
          await c.query<ScanRow>(
            'SELECT id, status::text AS status, client_session_id, patient_id FROM scans WHERE client_session_id = $1',
            [b.client_session_id],
          )
        ).rows[0];
        if (!s) return null;
        if (s.patient_id !== b.patient_id) {
          throw new ApiError(409, 'DS_SCAN_002', 'client_session_id already used for a different scan');
        }
        return s;
      };

      const out = await withRls(app.deps.pool, actor, async (c): Promise<CreateOutcome> => {
        const p = (
          await c.query<{ id: string; site_id: string; pseudonym_id: string }>(
            'SELECT id, site_id, pseudonym_id FROM patients WHERE id = $1',
            [b.patient_id],
          )
        ).rows[0];
        if (!p || p.site_id !== actor.siteId) throw notFound();

        // Serialise creations per patient so the session and 30-min checks see concurrent commits.
        await c.query(`SELECT pg_advisory_xact_lock(hashtextextended('scan-create:' || $1, 0))`, [p.id]);

        const existing = await existingFor(c);
        if (existing) {
          // The replay of an already stored session re-checks consent (it may have been withdrawn
          // since the scan was created); a block is audited post hoc and committed.
          const gate = await scanConsent(c, existing.id);
          if (!gate) throw notFound();
          if (gate.block) {
            await auditPostHocRejection(c, actor, actorRole(actor), existing.id, gate.block, gate.pseudonym);
            return { kind: 'consent', code: gate.block };
          }
          return { kind: 'existing', scan: existing };
        }

        const rejection = await consentRejection(c, p.id);
        if (rejection) {
          if (b.offline) {
            // Committed with this transaction, which writes nothing else.
            await audit(c, {
              eventType: 'capture_rejected_post_hoc',
              actorId: actor.id,
              actorRole: actorRole(actor),
              patientPseudonym: p.pseudonym_id,
              resourceType: 'scan',
              resourceId: b.client_session_id,
              outcome: rejection,
            });
          }
          return { kind: 'consent', code: rejection };
        }

        const dup = await c.query(
          `SELECT 1 FROM scans
            WHERE patient_id = $1 AND status <> 'revoked'
              AND abs(extract(epoch FROM (captured_at - $2::timestamptz))) < $3
            LIMIT 1`,
          [p.id, b.captured_at, DUPLICATE_WINDOW_SEC],
        );
        if (dup.rowCount) {
          throw new ApiError(409, 'DS_SCAN_001', 'Another scan for this patient was captured within 30 minutes');
        }

        const ins = await c.query<ScanRow>(
          `INSERT INTO scans (client_session_id, patient_id, site_id, device_id, operator_user_id,
                              captured_at, offline, protocol_version, status, metadata)
           VALUES ($1, $2, $3, NULL, $4, $5, $6, $7, 'capture_pending', $8::jsonb)
           ON CONFLICT (client_session_id) DO NOTHING
           RETURNING id, status::text AS status, client_session_id, patient_id`,
          [
            b.client_session_id,
            p.id,
            p.site_id,
            actor.id,
            b.captured_at,
            b.offline,
            b.protocol_version,
            JSON.stringify({ ...b.metadata, capture_steps: b.capture_steps }),
          ],
        );
        const scan = ins.rows[0];
        if (!scan) {
          // Lost a race on client_session_id (e.g. another patient's request): report what won.
          const winner = await existingFor(c);
          if (winner) return { kind: 'existing', scan: winner };
          throw new ApiError(409, 'DS_SCAN_002', 'client_session_id already used for a different scan');
        }

        if (b.device_attempts.length > 0) {
          await c.query(
            `INSERT INTO scan_step_attempts (scan_id, step, attempt, device_verdict, reason_codes)
             SELECT $1, (a->>'step')::capture_step, (a->>'attempt')::smallint, a->>'device_verdict',
                    ARRAY(SELECT jsonb_array_elements_text(a->'reason_codes'))
               FROM jsonb_array_elements($2::jsonb) a`,
            [scan.id, JSON.stringify(b.device_attempts)],
          );
        }
        await audit(c, {
          eventType: 'clinician_action',
          actorId: actor.id,
          actorRole: actorRole(actor),
          patientPseudonym: p.pseudonym_id,
          resourceType: 'scan',
          resourceId: scan.id,
          outcome: 'scan:create',
        });
        return { kind: 'created', scan };
      });

      if (out.kind === 'consent') throw new ApiError(451, out.code, CONSENT_MESSAGES[out.code]);
      return reply.status(out.kind === 'created' ? 201 : 200).send({ scan: scanRef(out.scan) });
    },
  );

  r.get(
    '/v1/scans/:id',
    { preHandler: requireUserOrDevice('nurse_operator', 'clinician'), schema: { params: IdParams } },
    async (req) => {
      const actor = actorOf(req);
      return withRls(app.deps.pool, actor, async (c) => {
        const s = (
          await c.query<{ id: string; status: string; site_id: string; patient_id: string; metadata: { capture_steps?: string[] } }>(
            'SELECT id, status::text AS status, site_id, patient_id, metadata FROM scans WHERE id = $1',
            [req.params.id],
          )
        ).rows[0];
        if (!s || s.site_id !== actor.siteId) throw notFound();
        if (actor.kind === 'user') {
          const p = (await c.query<{ pseudonym_id: string }>('SELECT pseudonym_id FROM patients WHERE id = $1', [s.patient_id])).rows[0];
          await audit(c, {
            eventType: 'data_access',
            actorId: actor.id,
            actorRole: actorRole(actor),
            patientPseudonym: p?.pseudonym_id ?? 'n/a',
            resourceType: 'scan',
            resourceId: s.id,
            outcome: 'success',
          });
        }
        return { scan: await scanView(c, s.id, s.status, s.metadata) };
      });
    },
  );

  r.post(
    '/v1/scans/:id/recapture',
    { preHandler: [site, idempotent()], schema: { params: IdParams, body: RecaptureBody } },
    async (req) => {
      const actor = actorOf(req);
      const { steps, trigger_reason_code } = req.body;
      const out = await withRls(app.deps.pool, actor, async (c): Promise<RecaptureOutcome> => {
        const s = (
          await c.query<{ id: string; status: string; site_id: string; metadata: { capture_steps?: string[]; unable_to_acquire?: string[] }; pseudonym_id: string }>(
            `SELECT s.id, s.status::text AS status, s.site_id, s.metadata, p.pseudonym_id
               FROM scans s JOIN patients p ON p.id = s.patient_id
              WHERE s.id = $1 FOR UPDATE OF s`,
            [req.params.id],
          )
        ).rows[0];
        if (!s || s.site_id !== actor.siteId) throw notFound();
        const gate = await scanConsent(c, s.id);
        if (!gate) throw notFound();
        if (gate.block) {
          await auditPostHocRejection(c, actor, actorRole(actor), s.id, gate.block, gate.pseudonym);
          return { kind: 'consent', code: gate.block };
        }

        const captured = s.metadata.capture_steps ?? [];
        const unknown = steps.filter((x) => !captured.includes(x));
        if (unknown.length) throw invalid('steps were not part of this capture', { steps: unknown });
        if (!RECAPTURABLE.has(s.status)) {
          throw new ApiError(409, 'DS_STATE_001', `Scan in status ${s.status} cannot be recaptured`);
        }

        const highest = new Map<string, number>(
          (
            await c.query<{ step: string; n: number }>(
              `SELECT step::text AS step, max(attempt)::int AS n FROM scan_step_attempts
                WHERE scan_id = $1 AND step = ANY($2::capture_step[]) GROUP BY step`,
              [s.id, steps],
            )
          ).rows.map((x) => [x.step, x.n]),
        );
        const auditRow = (outcome: string) =>
          audit(c, {
            eventType: 'clinician_action',
            actorId: actor.id,
            actorRole: actorRole(actor),
            patientPseudonym: s.pseudonym_id,
            resourceType: 'scan',
            resourceId: s.id,
            outcome,
            justification: trigger_reason_code,
          });

        const exhausted = steps.filter((x) => (highest.get(x) ?? 0) >= MAX_ATTEMPTS);
        const coreFailed = exhausted.some((x) => CORE_STEPS.has(x));
        // A core step out of attempts ends the capture: nothing else is recaptured.
        const recaptured = coreFailed ? [] : steps.filter((x) => !exhausted.includes(x));

        const priorUnable = s.metadata.unable_to_acquire ?? [];
        const unable = [...new Set([...priorUnable, ...exhausted])];
        const unableChanged = unable.length !== priorUnable.length;
        const status = coreFailed ? 'acquisition_failure' : recaptured.length ? 'capture_pending' : s.status;
        const statusChanged = status !== s.status;

        if (unableChanged || statusChanged) {
          await c.query(
            `UPDATE scans
                SET metadata = CASE WHEN $2 THEN jsonb_set(metadata, '{unable_to_acquire}', $3::jsonb) ELSE metadata END,
                    status = $4::scan_status
              WHERE id = $1`,
            [s.id, unableChanged, JSON.stringify(unable), status],
          );
        }
        if (recaptured.length) {
          await c.query(
            `INSERT INTO scan_step_attempts (scan_id, step, attempt, device_verdict, reason_codes)
             SELECT $1, t.step, t.attempt, 'RECAPTURE', ARRAY[$4::text]
               FROM unnest($2::capture_step[], $3::smallint[]) AS t(step, attempt)`,
            [s.id, recaptured, recaptured.map((x) => (highest.get(x) ?? 0) + 1), trigger_reason_code],
          );
        }

        if (exhausted.length) {
          // One audit row per call, and none when the call changed nothing (repeat of a known failure).
          if (unableChanged || statusChanged || recaptured.length) await auditRow('DS_QG_099');
          return { kind: 'exhausted', steps: exhausted, recaptured, status };
        }
        await auditRow('scan:recapture');
        return { kind: 'ok', view: await scanView(c, s.id, status, s.metadata) };
      });

      if (out.kind === 'consent') throw new ApiError(451, out.code, CONSENT_MESSAGES[out.code]);
      if (out.kind === 'exhausted') {
        throw new ApiError(422, 'DS_QG_099', 'Maximum recaptures reached; step marked UNABLE_TO_ACQUIRE', {
          unable_to_acquire: out.steps,
          recaptured: out.recaptured,
          status: out.status,
        });
      }
      return { scan: out.view };
    },
  );
}
