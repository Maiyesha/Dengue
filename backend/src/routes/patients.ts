// Patient lookup, ward roster and consent status (read-only; every read is audited as data_access).
import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import type { ZodTypeProvider } from 'fastify-type-provider-zod';
import { ApiError } from '../errors';
import { actorOf, requireUser, type Actor } from '../auth';
import { withRls } from '../db';
import { audit, NO_PATIENT } from '../audit';
import { consentBlock, type ConsentStatusRow } from '../consentGate';

const notFound = () => new ApiError(404, 'DS_NOT_FOUND', 'Resource not found');
const PARTICIPANT_CODE = /^DS-[A-Z]+-[0-9]{5}$/;

/**
 * Consent as shown to the ward app. capture_allowed / block_code (M4) come from consentBlock(),
 * the same rule the capture gate (POST /v1/scans, scan_consent_rejection) applies.
 */
const consentBody = (r: ConsentStatusRow | undefined, checkedAt: string) => {
  const block = consentBlock(r);
  return {
    primary_research: r?.primary_research ?? false,
    consent_version: r?.consent_version ?? '',
    current_version: r?.current_version ?? '',
    withdrawn: r?.withdrawn ?? false,
    capture_allowed: block === null,
    block_code: block,
    checked_at: checkedAt,
  };
};

const auditRead = (c: pg.PoolClient, a: Actor, pseudonym: string, type: string, id: string) =>
  audit(c, {
    eventType: 'data_access',
    actorId: a.id,
    actorRole: a.role,
    patientPseudonym: pseudonym,
    resourceType: type,
    resourceId: id,
    outcome: 'success',
  });

export async function patientRoutes(app: FastifyInstance): Promise<void> {
  const r = app.withTypeProvider<ZodTypeProvider>();
  const guard = requireUser('nurse_operator', 'clinician');

  r.get(
    '/v1/patients/lookup',
    { preHandler: guard, schema: { querystring: z.object({ participant_code: z.string().regex(PARTICIPANT_CODE) }).strict() } },
    async (req) => {
      const actor = actorOf(req);
      return withRls(app.deps.pool, actor, async (c) => {
        const p = (
          await c.query(
            `SELECT p.id, p.participant_code, p.pseudonym_id, p.bed_label, p.ward_id,
                    (SELECT max(s.captured_at) FROM scans s WHERE s.patient_id = p.id) AS last_captured_at
               FROM patients p WHERE p.participant_code = $1`,
            [req.query.participant_code],
          )
        ).rows[0];
        if (!p) throw notFound();
        await auditRead(c, actor, p.pseudonym_id, 'patient', p.id);
        return {
          patient_id: p.id,
          participant_code: p.participant_code,
          bed_label: p.bed_label,
          ward_id: p.ward_id,
          last_captured_at: p.last_captured_at ? new Date(p.last_captured_at).toISOString() : null,
        };
      });
    },
  );

  r.get(
    '/v1/wards/:wardId/roster',
    { preHandler: guard, schema: { params: z.object({ wardId: z.string().min(1).max(64) }) } },
    async (req) => {
      const actor = actorOf(req);
      return withRls(app.deps.pool, actor, async (c) => {
        const ward = (await c.query('SELECT site_id FROM wards WHERE id = $1', [req.params.wardId])).rows[0];
        if (!ward || ward.site_id !== actor.siteId) throw notFound();
        const generatedAt = app.deps.now().toISOString();
        const rows = (
          await c.query(
            `SELECT p.id, p.participant_code, p.bed_label,
                    cs.primary_research, cs.consent_version, cs.current_version, cs.withdrawn
               FROM patients p LEFT JOIN patient_consent_status cs ON cs.patient_id = p.id
              WHERE p.ward_id = $1 AND p.site_id = $2
              ORDER BY p.bed_label NULLS LAST, p.participant_code`,
            [req.params.wardId, ward.site_id],
          )
        ).rows;
        await auditRead(c, actor, NO_PATIENT, 'ward_roster', req.params.wardId);
        return {
          items: rows.map((x) => ({
            patient_id: x.id,
            participant_code: x.participant_code,
            bed_label: x.bed_label,
            consent: consentBody(x.consent_version === null ? undefined : x, generatedAt),
          })),
          generated_at: generatedAt,
        };
      });
    },
  );

  r.get(
    '/v1/patients/:id/consent-status',
    { preHandler: guard, schema: { params: z.object({ id: z.string().uuid() }) } },
    async (req) => {
      const actor = actorOf(req);
      return withRls(app.deps.pool, actor, async (c) => {
        const p = (await c.query('SELECT id, pseudonym_id FROM patients WHERE id = $1', [req.params.id])).rows[0];
        if (!p) throw notFound();
        const cs = (
          await c.query(
            `SELECT primary_research, consent_version, current_version, withdrawn
               FROM patient_consent_status WHERE patient_id = $1`,
            [p.id],
          )
        ).rows[0];
        await auditRead(c, actor, p.pseudonym_id, 'consent_status', p.id);
        return consentBody(cs, app.deps.now().toISOString());
      });
    },
  );
}
