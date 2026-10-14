// Reference vitals and labs. Idempotent per observation_id / lab id (retries are safe).
// Out-of-range vitals are stored and flagged INVALID by the DB trigger, never rejected.
// Units are fixed per vital / lab (VITAL_UNITS, LAB_UNITS); a different unit string is 400.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { ZodTypeProvider } from 'fastify-type-provider-zod';
import { ApiError } from '../errors';
import { actorOf, requireUser } from '../auth';
import { withRls } from '../db';
import { audit } from '../audit';
import { idempotent } from '../idempotency';
import { LAB_UNITS, VITAL_UNITS } from '../units';

const CLOCK_SKEW_MS = 5 * 60 * 1000;
const iso = z.string().datetime({ offset: true });

// Each vital / lab has exactly one accepted unit (F7); anything else is 400 DS_VALIDATION_001.

const table = (m: Record<string, string>) => Object.entries(m).map(([k, u]) => `${k}: "${u}"`).join(', ');
const unitMismatch = (ctx: z.RefinementCtx, expected: string) =>
  ctx.addIssue({ code: 'custom', path: ['unit'], message: `unit must be "${expected}"` });

const Observation = z
  .object({
    observation_id: z.string().uuid(),
    vital: z.enum(Object.keys(VITAL_UNITS) as [keyof typeof VITAL_UNITS, ...Array<keyof typeof VITAL_UNITS>]),
    value: z.number().finite(),
    unit: z.string().min(1).max(32).describe(`Fixed per vital (exact string): ${table(VITAL_UNITS)}`),
    source_device_type: z.string().min(1).max(100),
    measured_at: iso,
    scan_client_session_id: z.string().uuid().optional(),
  })
  .strict()
  .superRefine((o, ctx) => {
    if (o.unit !== VITAL_UNITS[o.vital]) unitMismatch(ctx, VITAL_UNITS[o.vital]);
  });

const Lab = z
  .object({
    id: z.string().uuid(),
    test: z.enum(Object.keys(LAB_UNITS) as [keyof typeof LAB_UNITS, ...Array<keyof typeof LAB_UNITS>]),
    value: z.number().finite(),
    unit: z.string().min(1).max(32).describe(`Fixed per test (exact string): ${table(LAB_UNITS)}`),
    collected_at: iso,
    methodology: z.string().min(1).max(200),
  })
  .strict()
  .superRefine((l, ctx) => {
    if (l.unit !== LAB_UNITS[l.test]) unitMismatch(ctx, LAB_UNITS[l.test]);
  });

const Body = z
  .object({ observations: z.array(Observation).max(500), labs: z.array(Lab).max(500).optional() })
  .strict();

const conflict = () => new ApiError(409, 'DS_CLINICAL_001', 'Identifier already in use');

export async function clinicalDataRoutes(app: FastifyInstance): Promise<void> {
  const r = app.withTypeProvider<ZodTypeProvider>();
  const guard = requireUser('nurse_operator', 'clinician');

  r.post(
    '/v1/patients/:id/clinical-data',
    {
      preHandler: [guard, idempotent()],
      schema: { params: z.object({ id: z.string().uuid() }), body: Body },
    },
    async (req, reply) => {
      const actor = actorOf(req);
      const b = req.body;
      const limit = app.deps.now().getTime() + CLOCK_SKEW_MS;
      for (const o of b.observations) {
        if (new Date(o.measured_at).getTime() > limit) {
          throw new ApiError(400, 'DS_VALIDATION_001', 'measured_at is in the future', {
            issues: [{ path: ['observations', 'measured_at'], message: 'measured_at is more than 5 minutes in the future' }],
          });
        }
      }

      const out = await withRls(app.deps.pool, actor, async (c) => {
        const p = (
          await c.query<{ id: string; site_id: string; pseudonym_id: string }>(
            'SELECT id, site_id, pseudonym_id FROM patients WHERE id = $1',
            [req.params.id],
          )
        ).rows[0];
        if (!p || p.site_id !== actor.siteId) throw new ApiError(404, 'DS_NOT_FOUND', 'Resource not found');

        let accepted = 0;
        let duplicates = 0;
        const invalid: string[] = [];

        for (const o of b.observations) {
          const ins = await c.query(
            `INSERT INTO clinical_observations
               (observation_id, patient_id, scan_client_session_id, observer_user_id, measured_at, vital, value, source_device_type)
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT (observation_id) DO NOTHING`,
            [o.observation_id, p.id, o.scan_client_session_id ?? null, actor.id, o.measured_at, o.vital, o.value, o.source_device_type],
          );
          if (ins.rowCount) {
            accepted++;
            const v = await c.query<{ validity: string }>(
              'SELECT validity FROM clinical_observations WHERE observation_id = $1',
              [o.observation_id],
            );
            if (v.rows[0]?.validity === 'INVALID') invalid.push(o.observation_id);
          } else {
            const same = await c.query(
              'SELECT 1 FROM clinical_observations WHERE observation_id = $1 AND patient_id = $2',
              [o.observation_id, p.id],
            );
            if (!same.rowCount) throw conflict();
            duplicates++;
          }
        }

        for (const l of b.labs ?? []) {
          const ins = await c.query(
            `INSERT INTO lab_values (id, patient_id, test, value, unit, collected_at, methodology)
             VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (id) DO NOTHING`,
            [l.id, p.id, l.test, l.value, l.unit, l.collected_at, l.methodology],
          );
          if (ins.rowCount) accepted++;
          else {
            const same = await c.query('SELECT 1 FROM lab_values WHERE id = $1 AND patient_id = $2', [l.id, p.id]);
            if (!same.rowCount) throw conflict();
            duplicates++;
          }
        }

        await audit(c, {
          eventType: 'clinician_action',
          actorId: actor.id,
          actorRole: actor.roles[0],
          patientPseudonym: p.pseudonym_id,
          resourceType: 'patient',
          resourceId: p.id,
          outcome: 'clinical_data:create',
        });
        return { accepted, duplicates, invalid };
      });
      return reply.status(201).send(out);
    },
  );
}
