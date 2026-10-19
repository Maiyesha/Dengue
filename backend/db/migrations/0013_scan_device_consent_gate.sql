-- Plan 02 final-review wave, F1 + F2.
--
-- F1. scans.device_id is set by the first artefact declare made with a device token. A `device`
--     session may only change device_id from NULL to itself (app_user_id()); any other change by
--     a device raises DS_STATE_002 (same code as the other immutable-column guards).
--
-- F2. scan_consent_rejection(scan_id) re-checks consent for an existing scan. Devices cannot read
--     patients/consents (RLS), so the gate is a SECURITY DEFINER function owned by the NOLOGIN role
--     consent_gate_owner, with a pinned search_path. It returns one row only when the scan is on the
--     caller's own site (site role or device), else no row:
--       block_code: NULL (capture allowed) | 'DS_REG_001' (no consent, withdrawn, not primary
--                   research, or the scan has no patient) | 'DS_REG_002' (superseded version)
--       pseudonym : the patient's pseudonym_id ('n/a' when the scan has no patient), used for the
--                   audit rows of device-token requests.
--     "Latest consent" is the same rule as patient_consent_status: recorded_at DESC, id DESC.
--     The same classification is implemented for the API in src/consentGate.ts (consentBlock()).

-- ---------------------------------------------------------------- F1 device_id guard
CREATE FUNCTION scans_device_id_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.device_id IS DISTINCT FROM OLD.device_id AND app_has_role('device') THEN
    IF OLD.device_id IS NOT NULL OR NEW.device_id IS NULL
       OR NEW.device_id::text IS DISTINCT FROM app_user_id() THEN
      RAISE EXCEPTION 'DS_STATE_002: a device may only set scans.device_id from NULL to itself'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER scans_device_id_guard BEFORE UPDATE ON scans
FOR EACH ROW EXECUTE FUNCTION scans_device_id_guard();

-- ---------------------------------------------------------------- F2 consent gate
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'consent_gate_owner') THEN
    CREATE ROLE consent_gate_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOINHERIT;
  END IF;
END $$;

-- Narrow column grants; RLS is forced on these tables, so the owner needs its own read policies.
-- The function itself restricts results to the caller's site.
GRANT SELECT (id, site_id, patient_id) ON scans TO consent_gate_owner;
GRANT SELECT (id, pseudonym_id) ON patients TO consent_gate_owner;
GRANT SELECT (id, patient_id, consent_version, primary_research, withdrawn_at, recorded_at) ON consents TO consent_gate_owner;
GRANT SELECT (version, is_current) ON consent_versions TO consent_gate_owner;
CREATE POLICY scans_consent_gate    ON scans    FOR SELECT TO consent_gate_owner USING (true);
CREATE POLICY patients_consent_gate ON patients FOR SELECT TO consent_gate_owner USING (true);
CREATE POLICY consents_consent_gate ON consents FOR SELECT TO consent_gate_owner USING (true);
GRANT EXECUTE ON FUNCTION app_has_role(text), app_site_id(), app_roles(), app_user_id(),
                          app_site_scoped(text), app_device_scoped(text) TO consent_gate_owner;

CREATE FUNCTION scan_consent_rejection(p_scan_id uuid)
RETURNS TABLE (block_code text, pseudonym text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT CASE
           WHEN lc.primary_research IS NULL OR lc.withdrawn_at IS NOT NULL OR NOT lc.primary_research
             THEN 'DS_REG_001'
           WHEN cv.version IS NULL OR lc.consent_version <> cv.version
             THEN 'DS_REG_002'
         END,
         COALESCE(p.pseudonym_id, 'n/a')
    FROM public.scans s
    LEFT JOIN public.patients p ON p.id = s.patient_id
    LEFT JOIN LATERAL (
      SELECT c.primary_research, c.consent_version, c.withdrawn_at
        FROM public.consents c
       WHERE c.patient_id = s.patient_id
       ORDER BY c.recorded_at DESC, c.id DESC
       LIMIT 1
    ) lc ON true
    LEFT JOIN public.consent_versions cv ON cv.is_current
   WHERE s.id = p_scan_id
     AND (public.app_site_scoped(s.site_id) OR public.app_device_scoped(s.site_id))
$$;
ALTER FUNCTION scan_consent_rejection(uuid) OWNER TO consent_gate_owner;
REVOKE ALL ON FUNCTION scan_consent_rejection(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION scan_consent_rejection(uuid) TO app_api;
