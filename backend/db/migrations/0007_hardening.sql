-- Final-review hardening for plan 01 (items refer to final-findings.md).
-- Only additive / replacing DDL; 0000-0006 are unchanged.

-- ================================================================ 1. one current consent version
-- At most one consent_versions row may be current, so "the current version" is unambiguous
-- (previously the view picked max(version) by TEXT order, e.g. 'v9' > 'v10').
CREATE UNIQUE INDEX consent_versions_one_current ON consent_versions ((true)) WHERE is_current;

-- ================================================================ 4. consents: append-only
-- recorded_at is the server-side append time and defines "latest consent". consented_at is
-- the clinical (client-supplied) time and may tie or arrive out of order (offline capture).
-- clock_timestamp() (not now()) so two rows appended in one transaction are still ordered.
ALTER TABLE consents ADD COLUMN recorded_at timestamptz NOT NULL DEFAULT clock_timestamp();
CREATE INDEX consents_patient_recorded_idx ON consents (patient_id, recorded_at DESC, id DESC);

-- Consent rows are never edited: a withdrawal or re-consent is a new row.
DROP POLICY consents_update ON consents;
REVOKE UPDATE ON consents FROM app_api;

-- Only clinician or admin may record consent, and only for a patient of the caller's own
-- app.site_id. Admin is site-less by default, so it must present app.site_id (fail closed).
-- The patients sub-select runs under the caller's RLS (clinician: own site; admin: all).
DROP POLICY consents_insert ON consents;
CREATE POLICY consents_insert ON consents FOR INSERT TO app_api
  WITH CHECK ((app_has_role('clinician') OR app_has_role('admin'))
              AND EXISTS (SELECT 1 FROM patients p
                          WHERE p.id = consents.patient_id AND p.site_id = app_site_id()));

-- Same columns as 0002; CREATE OR REPLACE keeps the owner and the app_api grant.
CREATE OR REPLACE VIEW patient_consent_status WITH (security_invoker = true) AS
SELECT DISTINCT ON (c.patient_id)
       c.patient_id,
       c.primary_research,
       c.consent_version,
       (SELECT v.version FROM consent_versions v WHERE v.is_current) AS current_version,
       (c.withdrawn_at IS NOT NULL) AS withdrawn
FROM consents c
ORDER BY c.patient_id, c.recorded_at DESC, c.id DESC;

-- Same latest-consent rule; view stays owned by research_definer (CREATE OR REPLACE keeps owner).
CREATE OR REPLACE VIEW research_consented_patients WITH (security_barrier = true) AS
SELECT p.id, p.pseudonym_id, p.cohort, p.status, p.site_id
FROM patients p
JOIN LATERAL (
  SELECT c.primary_research, c.withdrawn_at
  FROM consents c
  WHERE c.patient_id = p.id
  ORDER BY c.recorded_at DESC, c.id DESC
  LIMIT 1
) lc ON true
WHERE app_research_access()
  AND lc.primary_research
  AND lc.withdrawn_at IS NULL;

-- ================================================================ 5. research views drop revoked/excluded scans
CREATE OR REPLACE VIEW research_scans WITH (security_barrier = true) AS
SELECT s.id, cp.pseudonym_id, split_part(s.site_id, '-', 1) AS site_bucket,
       s.status, s.captured_at, s.protocol_version
FROM scans s
JOIN research_consented_patients cp ON cp.id = s.patient_id
WHERE app_research_access()
  AND s.status NOT IN ('revoked', 'excluded');

CREATE OR REPLACE VIEW research_features WITH (security_barrier = true) AS
SELECT f.scan_id, f.domain, f.name, f.value, f.pipeline_version, f.feature_availability_timestamp
FROM features f
JOIN scans s ON s.id = f.scan_id
JOIN research_consented_patients cp ON cp.id = s.patient_id
WHERE app_research_access()
  AND s.status NOT IN ('revoked', 'excluded');

CREATE OR REPLACE VIEW research_sqi_checks WITH (security_barrier = true) AS
SELECT q.scan_id, q.step, q.attempt, q.check_id, q.source, q.passed, q.metric_value, q.threshold, q.reason_code
FROM sqi_checks q
JOIN scans s ON s.id = q.scan_id
JOIN research_consented_patients cp ON cp.id = s.patient_id
WHERE app_research_access()
  AND s.status NOT IN ('revoked', 'excluded');

-- ================================================================ 2. sqi_checks source forgery
-- Site users may only write device-side rows; system_agent only server-side rows, and may
-- only update server-side rows (it can no longer rewrite a device verdict).
ALTER POLICY sqi_checks_insert_site ON sqi_checks
  WITH CHECK (source = 'device' AND EXISTS (SELECT 1 FROM scans s
              WHERE s.id = sqi_checks.scan_id AND app_site_scoped(s.site_id)));
ALTER POLICY sqi_checks_insert_agent ON sqi_checks
  WITH CHECK (app_has_role('system_agent') AND source = 'server');
ALTER POLICY sqi_checks_update_agent ON sqi_checks
  USING      (app_has_role('system_agent') AND source = 'server')
  WITH CHECK (app_has_role('system_agent') AND source = 'server');

-- ================================================================ 3. scan state-machine authority
-- Which app role may perform a (legal) transition. Multi-role sessions OR together.
CREATE FUNCTION scan_transition_authorized(from_s scan_status, to_s scan_status) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(CASE
    WHEN to_s = 'revoked'
      THEN app_has_role('nurse_operator') OR app_has_role('clinician')
    WHEN from_s = 'capture_pending' AND to_s IN ('quality_pending','acquisition_failure')
      THEN app_has_role('nurse_operator') OR app_has_role('clinician')
    WHEN from_s = 'quality_failed' AND to_s = 'capture_pending'
      THEN app_has_role('nurse_operator') OR app_has_role('clinician')
    WHEN from_s = 'quality_pending' AND to_s IN ('quality_passed','quality_failed','partial')
      THEN app_has_role('system_agent')
    WHEN from_s = 'quality_passed' AND to_s = 'feature_pending'
      THEN app_has_role('system_agent')
    WHEN from_s = 'feature_pending' AND to_s = 'feature_complete'
      THEN app_has_role('system_agent')
    WHEN from_s IN ('feature_complete','partial','acquisition_failure') AND to_s = 'review_pending'
      THEN app_has_role('system_agent')
    WHEN from_s = 'review_pending' AND to_s IN ('reviewed','flagged','excluded')
      THEN app_has_role('clinician')
    WHEN from_s IN ('reviewed','flagged','excluded') AND to_s = 'archived'
      THEN app_has_role('clinician') OR app_has_role('admin')
    -- Anything else (incl. the legal quality_failed -> acquisition_failure, which the ruling
    -- assigns to no role) is not authorised for application roles.
    ELSE false
  END, false)
$$;
GRANT EXECUTE ON FUNCTION scan_transition_authorized(scan_status, scan_status) TO app_api;

-- Exemption: role authority applies to every caller except a superuser or the owner of
-- `scans` (migrations, maintenance, superuser test setup). We deliberately key on
-- current_user's privileges rather than `current_user = 'app_api'`, so any future login role
-- that inherits app_api (current_user would then be the login role) is still checked.
-- Transition LEGALITY (DS_STATE_001) is still enforced for everyone, exempt or not.
CREATE FUNCTION scans_actor_exempt(tbl regclass) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT r.rolsuper FROM pg_catalog.pg_roles r WHERE r.rolname = current_user), false)
      OR (SELECT c.relowner FROM pg_catalog.pg_class c WHERE c.oid = tbl)
         = (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = current_user)
$$;
GRANT EXECUTE ON FUNCTION scans_actor_exempt(regclass) TO app_api;

-- Replaces the 0003 body: legality first (DS_STATE_001), then authority (DS_STATE_003).
CREATE OR REPLACE FUNCTION scans_status_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT scan_transition_allowed(OLD.status, NEW.status) THEN
      RAISE EXCEPTION 'DS_STATE_001: illegal scan status transition % -> %', OLD.status, NEW.status
        USING ERRCODE = 'P0001';
    END IF;
    IF NOT scans_actor_exempt(TG_RELID::regclass)
       AND NOT scan_transition_authorized(OLD.status, NEW.status) THEN
      RAISE EXCEPTION 'DS_STATE_003: roles % may not perform scan transition % -> %',
        app_roles(), OLD.status, NEW.status
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- New scans always start at capture_pending for application roles.
CREATE FUNCTION scans_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM 'capture_pending' AND NOT scans_actor_exempt(TG_RELID::regclass) THEN
    RAISE EXCEPTION 'DS_STATE_003: a new scan must start in capture_pending (got %)', NEW.status
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER scans_insert_guard BEFORE INSERT ON scans
FOR EACH ROW EXECUTE FUNCTION scans_insert_guard();

-- ================================================================ 9. devices / app_users exposure
-- Column-level SELECT only. devices: never push_token / attest_public_key.
-- app_users: never idp_subject (plan 02 identifies users by JWT sub = app_users.id).
REVOKE SELECT ON devices, app_users FROM app_api;
GRANT SELECT (id, site_id, ward_id, app_attest_key_id, assertion_counter, status) ON devices TO app_api;
GRANT SELECT (id, role, site_id) ON app_users TO app_api;

ALTER TABLE devices   ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices   FORCE  ROW LEVEL SECURITY;
ALTER TABLE app_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_users FORCE  ROW LEVEL SECURITY;

-- devices: site roles own site, system_agent all; admin/regulatory_reviewer all (they read
-- every participant table already). researcher/biostatistician: none.
CREATE POLICY devices_select ON devices FOR SELECT TO app_api
  USING (app_site_scoped(site_id) OR app_has_role('system_agent') OR app_reads_all());
-- app_users: site roles see users of their own site; admin sees all; nobody else.
CREATE POLICY app_users_select ON app_users FOR SELECT TO app_api
  USING (app_site_scoped(site_id) OR app_has_role('admin'));

-- ================================================================ 10. patient identifiers immutable
CREATE TRIGGER patients_immutable_ids BEFORE UPDATE ON patients
FOR EACH ROW EXECUTE FUNCTION forbid_column_change('pseudonym_id', 'participant_code');

-- ================================================================ 11. scans.site_id FK
ALTER TABLE scans ADD CONSTRAINT scans_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id);

-- ================================================================ 6/7/8. clinical_audit_log
-- 6. Reads restricted to admin + regulatory_reviewer; any app_api caller may append.
-- Consequence: a non-reader role cannot use INSERT ... RETURNING (RETURNING needs SELECT).
--
-- The chain trigger must see the newest row whatever the caller's RLS view is. Design:
-- trigger + verifier are SECURITY DEFINER owned by `audit_owner`, a NOLOGIN, NOBYPASSRLS,
-- non-superuser role whose only powers are SELECT on this table (through its own
-- USING (true) policy, so FORCE RLS stays on for everyone) and USAGE on the id sequence.
-- We prefer a per-table policy over BYPASSRLS: BYPASSRLS would apply to every table and
-- requires a superuser to grant.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'audit_owner') THEN
    CREATE ROLE audit_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOINHERIT;
  END IF;
END $$;

GRANT SELECT ON clinical_audit_log TO audit_owner;
GRANT USAGE ON SEQUENCE clinical_audit_log_id_seq TO audit_owner;

ALTER TABLE clinical_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinical_audit_log FORCE  ROW LEVEL SECURITY;

CREATE POLICY audit_select ON clinical_audit_log FOR SELECT TO app_api
  USING (app_has_role('admin') OR app_has_role('regulatory_reviewer'));
CREATE POLICY audit_insert ON clinical_audit_log FOR INSERT TO app_api
  WITH CHECK (true);
CREATE POLICY audit_owner_read ON clinical_audit_log FOR SELECT TO audit_owner
  USING (true);

-- 8. Canonical hash input: sha256 of jsonb_build_object(<all chained fields>)::text.
-- jsonb's text form is deterministic: keys are stored de-duplicated and sorted (by length,
-- then bytewise) independent of build order, with fixed ", " / ": " separators, and NULLs
-- are kept as JSON null (so NULL and '' no longer collide as they did with concat_ws).
-- occurred_at is rendered as fixed-format UTC text so the hash is TimeZone-independent.
CREATE OR REPLACE FUNCTION audit_compute_hash(r clinical_audit_log) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, public AS
$$ SELECT encode(digest(jsonb_build_object(
       'prev_row_hash',     r.prev_row_hash,
       'occurred_at',       to_char(r.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
       'event_type',        r.event_type,
       'actor_id_hash',     r.actor_id_hash,
       'actor_role',        r.actor_role,
       'patient_pseudonym', r.patient_pseudonym,
       'resource_type',     r.resource_type,
       'resource_id',       r.resource_id,
       'model_version',     r.model_version,
       'risk_band',         r.risk_band,
       'inputs_hash',       r.inputs_hash,
       'outputs_hash',      r.outputs_hash,
       'outcome',           r.outcome,
       'justification',     r.justification)::text, 'sha256'), 'hex') $$;

-- 7. The chain read below relies on READ COMMITTED: after taking the advisory lock, the
-- SELECT takes a fresh snapshot and so sees the previous holder's committed row. Under
-- REPEATABLE READ / SERIALIZABLE the snapshot predates the lock and the chain would fork.
-- 8. id, occurred_at, prev_row_hash and row_hash are always server-assigned.
CREATE OR REPLACE FUNCTION audit_chain_before_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'DS_AUD_002: clinical_audit_log inserts require READ COMMITTED isolation (got %)',
      current_setting('transaction_isolation')
      USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('clinical_audit_log'));
  NEW.id := nextval('public.clinical_audit_log_id_seq');
  NEW.occurred_at := clock_timestamp();
  NEW.prev_row_hash := NULL;
  SELECT l.row_hash INTO NEW.prev_row_hash FROM public.clinical_audit_log l ORDER BY l.id DESC LIMIT 1;
  IF NEW.prev_row_hash IS NULL THEN NEW.prev_row_hash := repeat('0', 64); END IF;
  NEW.row_hash := public.audit_compute_hash(NEW);
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION audit_verify_chain() RETURNS bigint
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  r public.clinical_audit_log;
  prev text := repeat('0', 64);
BEGIN
  FOR r IN SELECT * FROM public.clinical_audit_log ORDER BY id LOOP
    IF r.prev_row_hash IS DISTINCT FROM prev OR r.row_hash IS DISTINCT FROM public.audit_compute_hash(r) THEN
      RETURN r.id;
    END IF;
    prev := r.row_hash;
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION audit_chain_before_insert() OWNER TO audit_owner;
ALTER FUNCTION audit_verify_chain()        OWNER TO audit_owner;
REVOKE ALL ON FUNCTION audit_chain_before_insert() FROM PUBLIC;
REVOKE ALL ON FUNCTION audit_verify_chain()        FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit_verify_chain() TO app_api;
