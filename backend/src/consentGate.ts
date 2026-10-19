// Consent gate for capture.
//
//   no consent row | withdrawn | primary_research = false -> 451 DS_REG_001
//   consent_version <> current_version (superseded)        -> 451 DS_REG_002
//
// Checked in that order: a withdrawn or non-primary consent is DS_REG_001 even if its version is also old.
//
// Two entry points share this rule:
//   - consentRejection(patientId): POST /v1/scans before a scan exists. Reads patient_consent_status
//     (security_invoker, so the caller's RLS applies) and classifies it with consentBlock().
//   - scanConsent(scanId): every later capture step (artefact declare/complete, recapture, the
//     POST /v1/scans replay of an existing scan). Calls the SECURITY DEFINER function
//     scan_consent_rejection() (migration 0013), which applies the same rule in SQL and also works
//     for device tokens (devices cannot read patients/consents). It also returns the patient
//     pseudonym, used for device-token audit rows.
// consentBlock() is also what GET consent-status / the roster report as capture_allowed/block_code.
import type pg from 'pg';
import { audit } from './audit';
import type { Actor } from './auth';

export type ConsentRejection = 'DS_REG_001' | 'DS_REG_002';

export const CONSENT_MESSAGES: Record<ConsentRejection, string> = {
  DS_REG_001: 'Regulatory hold: no valid primary-research consent for this patient',
  DS_REG_002: 'Consent version superseded; re-consent required',
};

export interface ConsentStatusRow {
  primary_research: boolean;
  consent_version: string;
  current_version: string | null;
  withdrawn: boolean;
}

/** The single consent rule: null when capture is allowed, else the 451 code. `undefined` = no consent row. */
export function consentBlock(cs: ConsentStatusRow | undefined | null): ConsentRejection | null {
  if (!cs || cs.withdrawn || !cs.primary_research) return 'DS_REG_001';
  if (cs.current_version === null || cs.consent_version !== cs.current_version) return 'DS_REG_002';
  return null;
}

/** Returns null when capture is allowed, else the 451 error code. */
export async function consentRejection(c: pg.PoolClient, patientId: string): Promise<ConsentRejection | null> {
  const cs = (
    await c.query<ConsentStatusRow>(
      `SELECT primary_research, consent_version, current_version, withdrawn
         FROM patient_consent_status WHERE patient_id = $1`,
      [patientId],
    )
  ).rows[0];
  return consentBlock(cs);
}

export interface ScanConsent {
  block: ConsentRejection | null;
  /** Patient pseudonym ('n/a' if the scan has no patient). */
  pseudonym: string;
}

/** Consent re-check for an existing scan; null when the scan is not on the caller's site. */
export async function scanConsent(c: pg.PoolClient, scanId: string): Promise<ScanConsent | null> {
  const r = (
    await c.query<{ block_code: ConsentRejection | null; pseudonym: string }>(
      'SELECT block_code, pseudonym FROM scan_consent_rejection($1)',
      [scanId],
    )
  ).rows[0];
  return r ? { block: r.block_code, pseudonym: r.pseudonym } : null;
}

/**
 * Records a capture refused after the fact (consent no longer valid). Call inside withRls and let
 * that transaction COMMIT (return an outcome, throw the 451 after withRls) so the row persists.
 */
export function auditPostHocRejection(
  c: pg.PoolClient,
  actor: Actor,
  actorRole: string,
  resourceId: string,
  code: ConsentRejection,
  pseudonym: string,
): Promise<void> {
  return audit(c, {
    eventType: 'capture_rejected_post_hoc',
    actorId: actor.id,
    actorRole,
    patientPseudonym: pseudonym,
    resourceType: 'scan',
    resourceId,
    outcome: code,
  });
}
