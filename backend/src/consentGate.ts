// Consent gate for capture. Reads patient_consent_status (security_invoker, so the caller's RLS applies).
//
//   no consent row | withdrawn | primary_research = false -> 451 DS_REG_001
//   consent_version <> current_version (superseded)        -> 451 DS_REG_002
//
// Checked in that order: a withdrawn or non-primary consent is DS_REG_001 even if its version is also old.
import type pg from 'pg';

export type ConsentRejection = 'DS_REG_001' | 'DS_REG_002';

export const CONSENT_MESSAGES: Record<ConsentRejection, string> = {
  DS_REG_001: 'Regulatory hold: no valid primary-research consent for this patient',
  DS_REG_002: 'Consent version superseded; re-consent required',
};

/** Returns null when capture is allowed, else the 451 error code. */
export async function consentRejection(c: pg.PoolClient, patientId: string): Promise<ConsentRejection | null> {
  const cs = (
    await c.query<{ primary_research: boolean; consent_version: string; current_version: string | null; withdrawn: boolean }>(
      `SELECT primary_research, consent_version, current_version, withdrawn
         FROM patient_consent_status WHERE patient_id = $1`,
      [patientId],
    )
  ).rows[0];
  if (!cs || cs.withdrawn || !cs.primary_research) return 'DS_REG_001';
  if (cs.current_version === null || cs.consent_version !== cs.current_version) return 'DS_REG_002';
  return null;
}
