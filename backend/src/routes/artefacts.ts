// Artefact multipart uploads and the quality trigger. Callable by site users or a device token.
//
// Object key: captures/{site_id}/{scan_id}/{step}/{attempt}/{kind} (no participant code).
// Quality trigger (F9b): a core step is settled when its latest attempt is UNABLE_TO_ACQUIRE or it
// is in metadata.unable_to_acquire. When every non-settled core step's LATEST attempt has a video
// AND a roi_trace artefact in received_verified, and at least one core step is verified, the scan
// moves capture_pending -> quality_pending.
// Declare creates a missing step attempt (F9a: pre-registered scans; step must be in
// metadata.capture_steps, scan capture_pending; optional device_verdict, default ACCEPT).
// acquisition_failure scans (F9c) still accept declare/complete for EXISTING attempts; they never
// trigger or enqueue.
// The scan row is locked FOR UPDATE for declare/complete, so concurrent final completes
// serialise and exactly one UPDATE ... WHERE status='capture_pending' affects a row. Enqueue is
// at-least-once (F6): every complete that finds the scan quality_pending with its core artefacts
// verified enqueues after commit (incl. retries); the quality worker dedupes by scan_id.
//
// Upload recovery (F5): complete passes size_bytes to the store; missing parts -> 409
// DS_UPLOAD_005 (retryable, nothing changed). A completed-at-S3-but-rolled-back upload is
// recognised by the store (NoSuchUpload + HeadObject). A rejected artefact (sha mismatch) can be
// re-declared with the same sha: a new multipart upload is opened and the status returns to declared.
//
// Consent re-check (F2): declare and complete call scan_consent_rejection() right after the scan
// is located; a withdrawn/superseded consent is 451 DS_REG_001/002 with a committed
// capture_rejected_post_hoc audit row. The function also supplies the patient pseudonym used for
// every audit row of these routes (a device token cannot read patients).
// device_id (F1): the first declare made with a device token sets scans.device_id (if NULL).
import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import type { ZodTypeProvider } from 'fastify-type-provider-zod';
import { ApiError } from '../errors';
import { actorOf, requireUser, requireUserOrDevice, type Actor } from '../auth';
import { withRls } from '../db';
import { audit } from '../audit';
import { idempotent } from '../idempotency';
import { CONSENT_MESSAGES, auditPostHocRejection, scanConsent, type ConsentRejection } from '../consentGate';

const CORE_STEPS = ['neutral_face', 'fingertip_ppg'];
const PART_URL_TTL = 900 as const;

const notFound = () => new ApiError(404, 'DS_NOT_FOUND', 'Resource not found');

const DeclareBody = z
  .object({
    step: z.enum(['neutral_face', 'fingertip_ppg', 'ocular_capture', 'dorsal_tongue']),
    attempt: z.number().int().min(1).max(3),
    kind: z.enum(['video', 'roi_trace', 'metadata']),
    size_bytes: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
    sha256: z.string().regex(/^[0-9a-fA-F]{64}$/),
    device_verdict: z
      .enum(['ACCEPT', 'RECAPTURE', 'UNABLE_TO_ACQUIRE'])
      .default('ACCEPT')
      .describe('Used only when this declare creates the step attempt (pre-registered scans); ignored otherwise'),
  })
  .strict();

interface ScanMetadata {
  capture_steps?: string[];
  unable_to_acquire?: string[];
}

/** Artefacts are accepted while capturing, and for existing attempts after acquisition_failure (F9c). */
const ACCEPTS_ARTEFACTS = new Set(['capture_pending', 'acquisition_failure']);
function assertAcceptsArtefacts(status: string): void {
  if (!ACCEPTS_ARTEFACTS.has(status)) {
    throw new ApiError(409, 'DS_STATE_001', `Scan in status ${status} does not accept artefacts`);
  }
}

const ScanParams = z.object({ id: z.string().uuid() });
const ArtefactParams = z.object({ id: z.string().uuid() });
const PartParams = z.object({
  id: z.string().uuid(),
  n: z.coerce.number().int().min(1).max(10000),
});

interface ArtefactRow {
  id: string;
  sha256: string;
  object_key: string;
  upload_id: string | null;
  status: string;
}

/** Audit actor_role: the role that satisfied the route guard (M1). */
const actorRole = (a: Actor) => a.role;

type DeclareOutcome =
  | { kind: 'ok'; created: boolean; id: string; upload_id: string | null }
  | { kind: 'consent'; code: ConsentRejection };
const auditEvent = (a: Actor) => (a.kind === 'device' ? 'device_event' : 'clinician_action');

async function pseudonymOf(c: pg.PoolClient, scanId: string): Promise<string> {
  const r = await c.query<{ pseudonym_id: string }>(
    'SELECT p.pseudonym_id FROM scans s JOIN patients p ON p.id = s.patient_id WHERE s.id = $1',
    [scanId],
  );
  return r.rows[0]?.pseudonym_id ?? 'n/a';
}

/**
 * Quality trigger (F9b). A core step is SETTLED when its latest attempt's device_verdict is
 * UNABLE_TO_ACQUIRE or it is listed in metadata.unable_to_acquire. Ready when every non-settled
 * core step's latest attempt has verified video + roi_trace, and at least one core step is
 * verified. A core step with no attempt at all (and not settled) blocks the trigger.
 */
async function coreArtefactsVerified(c: pg.PoolClient, scanId: string, meta: ScanMetadata): Promise<boolean> {
  const r = await c.query<{ step: string; device_verdict: string | null; verified: boolean }>(
    `SELECT core.step::text AS step, l.device_verdict,
            (l.attempt IS NOT NULL AND
             (SELECT count(DISTINCT a.kind) FROM artefacts a
               WHERE a.scan_id = $1 AND a.step = core.step AND a.attempt = l.attempt
                 AND a.kind IN ('video','roi_trace') AND a.status = 'received_verified') = 2) AS verified
       FROM unnest($2::capture_step[]) AS core(step)
       LEFT JOIN LATERAL (
         SELECT t.attempt, t.device_verdict FROM scan_step_attempts t
          WHERE t.scan_id = $1 AND t.step = core.step ORDER BY t.attempt DESC LIMIT 1
       ) l ON true`,
    [scanId, CORE_STEPS],
  );
  const unable = meta.unable_to_acquire ?? [];
  const settled = (x: { step: string; device_verdict: string | null }) =>
    x.device_verdict === 'UNABLE_TO_ACQUIRE' || unable.includes(x.step);
  return r.rows.every((x) => settled(x) || x.verified) && r.rows.some((x) => x.verified);
}

export async function artefactRoutes(app: FastifyInstance): Promise<void> {
  const r = app.withTypeProvider<ZodTypeProvider>();
  const who = requireUserOrDevice('nurse_operator', 'clinician');
  const system = requireUser('system_agent');

  r.post(
    '/v1/scans/:id/artefacts',
    { preHandler: [who, idempotent()], schema: { params: ScanParams, body: DeclareBody } },
    async (req, reply) => {
      const actor = actorOf(req);
      const b = req.body;
      const sha = b.sha256.toLowerCase();
      const out = await withRls(app.deps.pool, actor, async (c): Promise<DeclareOutcome> => {
        const s = (
          await c.query<{ id: string; site_id: string; status: string; metadata: ScanMetadata }>(
            'SELECT id, site_id, status::text AS status, metadata FROM scans WHERE id = $1 FOR UPDATE',
            [req.params.id],
          )
        ).rows[0];
        if (!s || s.site_id !== actor.siteId) throw notFound();
        const gate = await scanConsent(c, s.id);
        if (!gate) throw notFound();
        if (gate.block) {
          // Committed: nothing else is written in this transaction.
          await auditPostHocRejection(c, actor, actorRole(actor), s.id, gate.block, gate.pseudonym);
          return { kind: 'consent', code: gate.block };
        }
        if (actor.kind === 'device') {
          // F1: the first device to declare becomes the scan's device (push target for
          // request_repeat). Never overwritten; the 0013 trigger enforces this for devices.
          await c.query('UPDATE scans SET device_id = $2 WHERE id = $1 AND device_id IS NULL', [s.id, actor.id]);
        }

        const existing = (
          await c.query<ArtefactRow>(
            `SELECT id, sha256, object_key, upload_id, status FROM artefacts
              WHERE scan_id = $1 AND step = $2::capture_step AND attempt = $3 AND kind = $4`,
            [s.id, b.step, b.attempt, b.kind],
          )
        ).rows[0];
        if (existing) {
          if (existing.sha256 !== sha) {
            throw new ApiError(409, 'DS_UPLOAD_003', 'Artefact already declared with a different sha256');
          }
          if (existing.status !== 'rejected') {
            return { kind: 'ok', created: false, id: existing.id, upload_id: existing.upload_id };
          }
          // F5: a rejected artefact (sha mismatch) is re-uploaded under a NEW multipart upload.
          assertAcceptsArtefacts(s.status);
          const uploadId = await app.deps.objectStore.createMultipart(existing.object_key);
          await c.query(
            `UPDATE artefacts SET upload_id = $2, size_bytes = $3, status = 'declared' WHERE id = $1 AND status = 'rejected'`,
            [existing.id, uploadId, b.size_bytes],
          );
          await audit(c, {
            eventType: auditEvent(actor),
            actorId: actor.id,
            actorRole: actorRole(actor),
            patientPseudonym: gate.pseudonym,
            resourceType: 'artefact',
            resourceId: existing.id,
            outcome: 'artefact:redeclare',
          });
          return { kind: 'ok', created: false, id: existing.id, upload_id: uploadId };
        }

        const att = await c.query(
          'SELECT 1 FROM scan_step_attempts WHERE scan_id = $1 AND step = $2::capture_step AND attempt = $3',
          [s.id, b.step, b.attempt],
        );
        if (!att.rowCount) {
          // F9(a): create the missing attempt (POST /v1/scans pre-registration sends none), but
          // only for a step of this capture and only while the capture is open.
          if (!(s.metadata.capture_steps ?? []).includes(b.step)) {
            throw new ApiError(422, 'DS_UPLOAD_002', 'No such step for this scan');
          }
          if (s.status !== 'capture_pending') {
            throw new ApiError(409, 'DS_STATE_001', `Scan in status ${s.status} does not accept new step attempts`);
          }
          await c.query(
            `INSERT INTO scan_step_attempts (scan_id, step, attempt, device_verdict, reason_codes)
             VALUES ($1, $2::capture_step, $3, $4, '{}') ON CONFLICT DO NOTHING`,
            [s.id, b.step, b.attempt, b.device_verdict],
          );
        }
        assertAcceptsArtefacts(s.status);

        const key = `captures/${s.site_id}/${s.id}/${b.step}/${b.attempt}/${b.kind}`;
        const uploadId = await app.deps.objectStore.createMultipart(key);
        const ins = await c.query<{ id: string }>(
          `INSERT INTO artefacts (scan_id, step, attempt, kind, size_bytes, sha256, object_key, upload_id, status)
           VALUES ($1, $2::capture_step, $3, $4, $5, $6, $7, $8, 'declared') RETURNING id`,
          [s.id, b.step, b.attempt, b.kind, b.size_bytes, sha, key, uploadId],
        );
        const id = ins.rows[0].id;
        await audit(c, {
          eventType: auditEvent(actor),
          actorId: actor.id,
          actorRole: actorRole(actor),
          patientPseudonym: gate.pseudonym,
          resourceType: 'artefact',
          resourceId: id,
          outcome: 'artefact:declare',
        });
        return { kind: 'ok', created: true, id, upload_id: uploadId };
      });
      if (out.kind === 'consent') throw new ApiError(451, out.code, CONSENT_MESSAGES[out.code]);
      return reply.status(out.created ? 201 : 200).send({ artefact_id: out.id, upload_id: out.upload_id });
    },
  );

  r.post(
    '/v1/artefacts/:id/parts/:n/url',
    // Exempt from idempotency: a stored response would replay a stale (possibly expired) presigned
    // URL. Re-issuing a URL is safe; the declared -> uploading move is guarded by its WHERE.
    { preHandler: [who], config: { idempotencyExempt: true }, schema: { params: PartParams } },
    async (req) => {
      const actor = actorOf(req);
      const a = await withRls(app.deps.pool, actor, async (c) => {
        const row = (
          await c.query<ArtefactRow & { site_id: string }>(
            `SELECT a.id, a.object_key, a.upload_id, a.status, s.site_id
               FROM artefacts a JOIN scans s ON s.id = a.scan_id WHERE a.id = $1`,
            [req.params.id],
          )
        ).rows[0];
        if (!row || row.site_id !== actor.siteId) throw notFound();
        if (!row.upload_id || (row.status !== 'declared' && row.status !== 'uploading')) {
          throw new ApiError(409, 'DS_UPLOAD_004', `Artefact in status ${row.status} does not accept parts`);
        }
        if (row.status === 'declared') {
          await c.query(`UPDATE artefacts SET status = 'uploading' WHERE id = $1 AND status = 'declared'`, [row.id]);
        }
        return row;
      });
      const url = await app.deps.objectStore.presignPart(a.object_key, a.upload_id!, req.params.n, PART_URL_TTL);
      return { url, expires_in: PART_URL_TTL };
    },
  );

  r.post(
    '/v1/artefacts/:id/complete',
    { preHandler: [who, idempotent()], schema: { params: ArtefactParams } },
    async (req) => {
      const actor = actorOf(req);
      const out = await withRls(app.deps.pool, actor, async (c) => {
        const ref = (
          await c.query<{ scan_id: string }>('SELECT scan_id FROM artefacts WHERE id = $1', [req.params.id])
        ).rows[0];
        if (!ref) throw notFound();
        // Lock the scan first (same order as declare) so final completes serialise.
        const s = (
          await c.query<{ id: string; site_id: string; metadata: ScanMetadata }>(
            'SELECT id, site_id, metadata FROM scans WHERE id = $1 FOR UPDATE',
            [ref.scan_id],
          )
        ).rows[0];
        if (!s || s.site_id !== actor.siteId) throw notFound();
        const gate = await scanConsent(c, s.id);
        if (!gate) throw notFound();
        if (gate.block) {
          await auditPostHocRejection(c, actor, actorRole(actor), s.id, gate.block, gate.pseudonym);
          return { kind: 'consent' as const, code: gate.block };
        }
        const a = (
          await c.query<ArtefactRow & { size_bytes: string }>(
            'SELECT id, sha256, object_key, upload_id, status, size_bytes FROM artefacts WHERE id = $1',
            [req.params.id],
          )
        ).rows[0];
        if (!a) throw notFound();

        let verified = a.status === 'received_verified';
        if (!verified) {
          if (a.status !== 'rejected') {
            const size = Number(a.size_bytes);
            const done = await app.deps.objectStore.completeMultipart(a.object_key, a.upload_id ?? '', size);
            // Parts missing: nothing has been written yet; commit the empty transaction and report.
            if (!done.completed) return { kind: 'incomplete' as const, received: done.receivedBytes, size };
          }
          const actual = (await app.deps.objectStore.sha256(a.object_key)).toLowerCase();
          verified = actual === a.sha256.toLowerCase();
          await c.query('UPDATE artefacts SET status = $2 WHERE id = $1', [
            a.id,
            verified ? 'received_verified' : 'rejected',
          ]);
          await audit(c, {
            eventType: auditEvent(actor),
            actorId: actor.id,
            actorRole: actorRole(actor),
            patientPseudonym: gate.pseudonym,
            resourceType: 'artefact',
            resourceId: a.id,
            outcome: verified ? 'artefact:complete' : 'artefact:rejected_sha256_mismatch',
          });
        }
        if (!verified) return { kind: 'mismatch' as const };

        // F6: enqueue at least once. Whenever the scan is (now) quality_pending and its core
        // artefacts are verified, enqueue after commit -- also on a retry, so an enqueue that failed
        // after an earlier commit is redelivered. The quality worker must dedupe by scan_id.
        let enqueue = false;
        if (await coreArtefactsVerified(c, s.id, s.metadata)) {
          await c.query(
            `UPDATE scans SET status = 'quality_pending' WHERE id = $1 AND status = 'capture_pending'`,
            [s.id],
          );
          const now = (await c.query<{ status: string }>('SELECT status::text AS status FROM scans WHERE id = $1', [s.id]))
            .rows[0];
          enqueue = now?.status === 'quality_pending';
        }
        return { kind: 'verified' as const, enqueue, scanId: s.id };
      });

      if (out.kind === 'consent') throw new ApiError(451, out.code, CONSENT_MESSAGES[out.code]);
      if (out.kind === 'incomplete') {
        // Retryable: the claim is released so the same Idempotency-Key can be reused once the
        // remaining parts are uploaded.
        req.idempotencyRelease = true;
        throw new ApiError(409, 'DS_UPLOAD_005', 'Upload is incomplete: uploaded parts are smaller than size_bytes', {
          received_bytes: out.received,
          size_bytes: out.size,
        });
      }
      if (out.kind === 'mismatch') {
        throw new ApiError(422, 'DS_UPLOAD_001', 'Uploaded object sha256 does not match the declared value');
      }
      if (out.enqueue) await app.deps.qualityQueue.enqueue(out.scanId);
      return { status: 'received_verified' as const };
    },
  );

  // Feature extraction is system_agent only and requires a passed quality gate (doc 04, section 4.6).
  r.post(
    '/v1/scans/:id/features/extract',
    { preHandler: [system, idempotent()], schema: { params: ScanParams } },
    async (req, reply) => {
      const actor = actorOf(req);
      await withRls(app.deps.pool, actor, async (c) => {
        const s = (
          await c.query<{ id: string; status: string }>('SELECT id, status::text AS status FROM scans WHERE id = $1', [
            req.params.id,
          ])
        ).rows[0];
        if (!s) throw notFound();
        if (s.status !== 'quality_passed') {
          throw new ApiError(422, 'DS_QG_000', `Scan in status ${s.status} has not passed the quality gate`);
        }
        await audit(c, {
          eventType: 'data_access',
          actorId: actor.id,
          actorRole: actorRole(actor),
          patientPseudonym: await pseudonymOf(c, s.id),
          resourceType: 'scan',
          resourceId: s.id,
          outcome: 'features:extract_requested',
        });
      });
      return reply.status(202).send({ scan_id: req.params.id, status: 'extraction_accepted' });
    },
  );
}
