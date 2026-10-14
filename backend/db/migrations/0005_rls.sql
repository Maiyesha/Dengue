-- Task 5: row-level security per role and site (doc 04 §2.3).
--
-- All application traffic runs as app_api; the effective app role(s) and site come from
-- app.roles / app.site_id (see 0001 helpers). Policies are permissive and OR together.
--   nurse_operator, clinician : rows of their own site only (app_site_id()); none when unset.
--   admin, regulatory_reviewer: read all, write nothing.
--   researcher, biostatistician: no direct rows anywhere; read only via research_* views.
--   system_agent              : read/update scans, artefacts, sqi_checks, features (all sites).
--   scan_reviews INSERT       : clinician only, own site, as themselves.
-- No DELETE is granted on any participant-data table.

-- ---------------------------------------------------------------- helpers
CREATE FUNCTION app_site_scoped(s text) RETURNS boolean LANGUAGE sql STABLE AS
$$ SELECT COALESCE((app_has_role('nurse_operator') OR app_has_role('clinician')) AND s = app_site_id(), false) $$;

CREATE FUNCTION app_reads_all() RETURNS boolean LANGUAGE sql STABLE AS
$$ SELECT app_has_role('admin') OR app_has_role('regulatory_reviewer') $$;

CREATE FUNCTION app_research_access() RETURNS boolean LANGUAGE sql STABLE AS
$$ SELECT app_has_role('researcher') OR app_has_role('biostatistician')
       OR app_has_role('admin') OR app_has_role('regulatory_reviewer') $$;

-- Owner of the de-identified research views. Never granted to app_api, cannot log in.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'research_definer') THEN
    CREATE ROLE research_definer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
END $$;

GRANT EXECUTE ON FUNCTION app_site_scoped(text), app_reads_all(), app_research_access()
  TO app_api, research_definer;

-- ---------------------------------------------------------------- reference tables
GRANT SELECT ON sites, wards, app_users, devices, consent_versions TO app_api;

-- ---------------------------------------------------------------- enable + force RLS
ALTER TABLE patients              ENABLE ROW LEVEL SECURITY;
ALTER TABLE consents              ENABLE ROW LEVEL SECURITY;
ALTER TABLE scans                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE scan_step_attempts    ENABLE ROW LEVEL SECURITY;
ALTER TABLE artefacts             ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinical_observations ENABLE ROW LEVEL SECURITY;
ALTER TABLE lab_values            ENABLE ROW LEVEL SECURITY;
ALTER TABLE sqi_checks            ENABLE ROW LEVEL SECURITY;
ALTER TABLE features              ENABLE ROW LEVEL SECURITY;
ALTER TABLE scan_reviews          ENABLE ROW LEVEL SECURITY;

ALTER TABLE patients              FORCE ROW LEVEL SECURITY;
ALTER TABLE consents              FORCE ROW LEVEL SECURITY;
ALTER TABLE scans                 FORCE ROW LEVEL SECURITY;
ALTER TABLE scan_step_attempts    FORCE ROW LEVEL SECURITY;
ALTER TABLE artefacts             FORCE ROW LEVEL SECURITY;
ALTER TABLE clinical_observations FORCE ROW LEVEL SECURITY;
ALTER TABLE lab_values            FORCE ROW LEVEL SECURITY;
ALTER TABLE sqi_checks            FORCE ROW LEVEL SECURITY;
ALTER TABLE features              FORCE ROW LEVEL SECURITY;
ALTER TABLE scan_reviews          FORCE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------- table grants (no DELETE)
GRANT SELECT, INSERT, UPDATE ON patients, consents, scans, artefacts, sqi_checks, features TO app_api;
GRANT SELECT, INSERT         ON scan_step_attempts, clinical_observations, lab_values, scan_reviews TO app_api;

-- ---------------------------------------------------------------- patients
CREATE POLICY patients_select ON patients FOR SELECT TO app_api
  USING (app_site_scoped(site_id) OR app_reads_all());
CREATE POLICY patients_insert ON patients FOR INSERT TO app_api
  WITH CHECK (app_site_scoped(site_id));
CREATE POLICY patients_update ON patients FOR UPDATE TO app_api
  USING (app_site_scoped(site_id)) WITH CHECK (app_site_scoped(site_id));

-- ---------------------------------------------------------------- patient-scoped children
CREATE POLICY consents_select ON consents FOR SELECT TO app_api
  USING (app_reads_all() OR EXISTS (SELECT 1 FROM patients p
         WHERE p.id = consents.patient_id AND app_site_scoped(p.site_id)));
CREATE POLICY consents_insert ON consents FOR INSERT TO app_api
  WITH CHECK (EXISTS (SELECT 1 FROM patients p
              WHERE p.id = consents.patient_id AND app_site_scoped(p.site_id)));
CREATE POLICY consents_update ON consents FOR UPDATE TO app_api
  USING      (EXISTS (SELECT 1 FROM patients p WHERE p.id = consents.patient_id AND app_site_scoped(p.site_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM patients p WHERE p.id = consents.patient_id AND app_site_scoped(p.site_id)));

CREATE POLICY clinical_observations_select ON clinical_observations FOR SELECT TO app_api
  USING (app_reads_all() OR EXISTS (SELECT 1 FROM patients p
         WHERE p.id = clinical_observations.patient_id AND app_site_scoped(p.site_id)));
CREATE POLICY clinical_observations_insert ON clinical_observations FOR INSERT TO app_api
  WITH CHECK (EXISTS (SELECT 1 FROM patients p
              WHERE p.id = clinical_observations.patient_id AND app_site_scoped(p.site_id)));

CREATE POLICY lab_values_select ON lab_values FOR SELECT TO app_api
  USING (app_reads_all() OR EXISTS (SELECT 1 FROM patients p
         WHERE p.id = lab_values.patient_id AND app_site_scoped(p.site_id)));
CREATE POLICY lab_values_insert ON lab_values FOR INSERT TO app_api
  WITH CHECK (EXISTS (SELECT 1 FROM patients p
              WHERE p.id = lab_values.patient_id AND app_site_scoped(p.site_id)));

-- ---------------------------------------------------------------- scans
CREATE POLICY scans_select ON scans FOR SELECT TO app_api
  USING (app_site_scoped(site_id) OR app_reads_all() OR app_has_role('system_agent'));
-- A site user may only attach a scan to a patient of the same site.
CREATE POLICY scans_insert ON scans FOR INSERT TO app_api
  WITH CHECK (app_site_scoped(site_id) AND (patient_id IS NULL OR EXISTS (
              SELECT 1 FROM patients p WHERE p.id = scans.patient_id AND p.site_id = scans.site_id)));
CREATE POLICY scans_update_site ON scans FOR UPDATE TO app_api
  USING (app_site_scoped(site_id))
  WITH CHECK (app_site_scoped(site_id) AND (patient_id IS NULL OR EXISTS (
              SELECT 1 FROM patients p WHERE p.id = scans.patient_id AND p.site_id = scans.site_id)));
CREATE POLICY scans_update_agent ON scans FOR UPDATE TO app_api
  USING (app_has_role('system_agent')) WITH CHECK (app_has_role('system_agent'));

-- ---------------------------------------------------------------- scan-scoped children
CREATE POLICY scan_step_attempts_select ON scan_step_attempts FOR SELECT TO app_api
  USING (app_reads_all() OR EXISTS (SELECT 1 FROM scans s
         WHERE s.id = scan_step_attempts.scan_id AND app_site_scoped(s.site_id)));
CREATE POLICY scan_step_attempts_insert ON scan_step_attempts FOR INSERT TO app_api
  WITH CHECK (EXISTS (SELECT 1 FROM scans s
              WHERE s.id = scan_step_attempts.scan_id AND app_site_scoped(s.site_id)));

CREATE POLICY artefacts_select ON artefacts FOR SELECT TO app_api
  USING (app_reads_all() OR app_has_role('system_agent') OR EXISTS (SELECT 1 FROM scans s
         WHERE s.id = artefacts.scan_id AND app_site_scoped(s.site_id)));
CREATE POLICY artefacts_insert ON artefacts FOR INSERT TO app_api
  WITH CHECK (EXISTS (SELECT 1 FROM scans s
              WHERE s.id = artefacts.scan_id AND app_site_scoped(s.site_id)));
CREATE POLICY artefacts_update_site ON artefacts FOR UPDATE TO app_api
  USING      (EXISTS (SELECT 1 FROM scans s WHERE s.id = artefacts.scan_id AND app_site_scoped(s.site_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM scans s WHERE s.id = artefacts.scan_id AND app_site_scoped(s.site_id)));
CREATE POLICY artefacts_update_agent ON artefacts FOR UPDATE TO app_api
  USING (app_has_role('system_agent')) WITH CHECK (app_has_role('system_agent'));

-- Device-side SQI rows are written by site users; server-side rows by system_agent.
CREATE POLICY sqi_checks_select ON sqi_checks FOR SELECT TO app_api
  USING (app_reads_all() OR app_has_role('system_agent') OR EXISTS (SELECT 1 FROM scans s
         WHERE s.id = sqi_checks.scan_id AND app_site_scoped(s.site_id)));
CREATE POLICY sqi_checks_insert_site ON sqi_checks FOR INSERT TO app_api
  WITH CHECK (EXISTS (SELECT 1 FROM scans s
              WHERE s.id = sqi_checks.scan_id AND app_site_scoped(s.site_id)));
CREATE POLICY sqi_checks_insert_agent ON sqi_checks FOR INSERT TO app_api
  WITH CHECK (app_has_role('system_agent'));
CREATE POLICY sqi_checks_update_agent ON sqi_checks FOR UPDATE TO app_api
  USING (app_has_role('system_agent')) WITH CHECK (app_has_role('system_agent'));

-- Features are produced by system_agent; site users read them (experimental display).
CREATE POLICY features_select ON features FOR SELECT TO app_api
  USING (app_reads_all() OR app_has_role('system_agent') OR EXISTS (SELECT 1 FROM scans s
         WHERE s.id = features.scan_id AND app_site_scoped(s.site_id)));
CREATE POLICY features_insert_agent ON features FOR INSERT TO app_api
  WITH CHECK (app_has_role('system_agent'));
CREATE POLICY features_update_agent ON features FOR UPDATE TO app_api
  USING (app_has_role('system_agent')) WITH CHECK (app_has_role('system_agent'));

CREATE POLICY scan_reviews_select ON scan_reviews FOR SELECT TO app_api
  USING (app_reads_all() OR EXISTS (SELECT 1 FROM scans s
         WHERE s.id = scan_reviews.scan_id AND app_site_scoped(s.site_id)));
CREATE POLICY scan_reviews_insert ON scan_reviews FOR INSERT TO app_api
  WITH CHECK (app_has_role('clinician')
              AND reviewer_user_id = app_user_id()
              AND EXISTS (SELECT 1 FROM scans s
                          WHERE s.id = scan_reviews.scan_id AND s.site_id = app_site_id()));

-- ---------------------------------------------------------------- consent status view
-- security_invoker view (0002): consents/consent_versions RLS + grants apply to the caller.
GRANT SELECT ON patient_consent_status TO app_api;

-- ---------------------------------------------------------------- research views
-- Owned by research_definer, so researchers read across sites without any direct policy on
-- the base tables. Each view gates on app_research_access() itself, and research_definer's
-- base-table policies repeat the gate (defence in depth). security_barrier stops caller
-- predicates from being pushed below the gate.
GRANT SELECT ON patients, scans, features, sqi_checks TO research_definer;

CREATE POLICY patients_research   ON patients   FOR SELECT TO research_definer USING (app_research_access());
CREATE POLICY scans_research      ON scans      FOR SELECT TO research_definer USING (app_research_access());
CREATE POLICY features_research   ON features   FOR SELECT TO research_definer USING (app_research_access());
CREATE POLICY sqi_checks_research ON sqi_checks FOR SELECT TO research_definer USING (app_research_access());

CREATE VIEW research_patients WITH (security_barrier = true) AS
SELECT p.pseudonym_id, p.cohort, p.status, split_part(p.site_id, '-', 1) AS site_bucket
FROM patients p
WHERE app_research_access();

CREATE VIEW research_scans WITH (security_barrier = true) AS
SELECT s.id, split_part(s.site_id, '-', 1) AS site_bucket, s.status, s.captured_at, s.protocol_version
FROM scans s
WHERE app_research_access();

CREATE VIEW research_features WITH (security_barrier = true) AS
SELECT f.scan_id, f.domain, f.name, f.value, f.pipeline_version, f.feature_availability_timestamp
FROM features f
WHERE app_research_access();

CREATE VIEW research_sqi_checks WITH (security_barrier = true) AS
SELECT q.scan_id, q.step, q.attempt, q.check_id, q.source, q.passed, q.metric_value, q.threshold, q.reason_code
FROM sqi_checks q
WHERE app_research_access();

ALTER VIEW research_patients   OWNER TO research_definer;
ALTER VIEW research_scans      OWNER TO research_definer;
ALTER VIEW research_features   OWNER TO research_definer;
ALTER VIEW research_sqi_checks OWNER TO research_definer;

REVOKE ALL ON research_patients, research_scans, research_features, research_sqi_checks FROM PUBLIC;
GRANT SELECT ON research_patients, research_scans, research_features, research_sqi_checks TO app_api;
