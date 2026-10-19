// Clinical audit writer. Call inside withRls(), in the same transaction as the mutation it
// records, so a failed audit insert rolls the mutation back (403 DS_AUD_001).
import { createHash } from 'node:crypto';
import type pg from 'pg';
import { ApiError } from './errors';

/** patient_pseudonym for events that concern no patient. */
export const NO_PATIENT = 'n/a';

export interface AuditEvent {
  eventType: string;
  actorId: string;
  actorRole: string;
  patientPseudonym: string;
  resourceType: string;
  resourceId: string;
  outcome: string;
  justification?: string;
}

export const sha256Hex = (s: string) => createHash('sha256').update(s, 'utf8').digest('hex');

/**
 * Appends one clinical_audit_log row. id, occurred_at and the chain hashes are set by the DB
 * trigger. No RETURNING: most app roles may INSERT but not SELECT the log.
 * Any failure throws ApiError(403, 'DS_AUD_001'); the caller's transaction is then aborted.
 */
export async function audit(c: pg.PoolClient, e: AuditEvent): Promise<void> {
  try {
    await c.query(
      `INSERT INTO clinical_audit_log
         (event_type, actor_id_hash, actor_role, patient_pseudonym, resource_type, resource_id, outcome, justification)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [
        e.eventType,
        sha256Hex(e.actorId),
        e.actorRole,
        e.patientPseudonym,
        e.resourceType,
        e.resourceId,
        e.outcome,
        e.justification ?? null,
      ],
    );
  } catch {
    throw new ApiError(403, 'DS_AUD_001', 'Audit record could not be written; the operation was not performed');
  }
}
