-- Plan 02 Task 2: the `device` app role, plus quality_failed -> acquisition_failure for site roles.
--
-- A device token runs inside withRls() as app_api with app.roles = 'device', app.user_id = the
-- device id and app.site_id = the device's site. `device` is not an app_users role (devices are
-- not users), so app_role is unchanged; app.roles is free text read by app_has_role().
--
-- device may:
--   scans     : SELECT, UPDATE rows of its own site (no INSERT: scans are created by users).
--   artefacts : SELECT, INSERT, UPDATE rows whose scan is on its own site.
--   authority : capture_pending -> quality_pending only (upload complete).
-- Everything else (patients, consents, clinical data, other transitions) stays closed.
-- Immutable linkage columns (scans.site_id/patient_id, artefacts.scan_id) are still enforced
-- by the 0005 triggers for every role.

CREATE FUNCTION app_device_scoped(s text) RETURNS boolean LANGUAGE sql STABLE AS
$$ SELECT COALESCE(app_has_role('device') AND s = app_site_id(), false) $$;
GRANT EXECUTE ON FUNCTION app_device_scoped(text) TO app_api;

-- ---------------------------------------------------------------- scans
CREATE POLICY scans_select_device ON scans FOR SELECT TO app_api
  USING (app_device_scoped(site_id));
CREATE POLICY scans_update_device ON scans FOR UPDATE TO app_api
  USING (app_device_scoped(site_id)) WITH CHECK (app_device_scoped(site_id));

-- ---------------------------------------------------------------- artefacts
-- The scans sub-select runs under the caller's own RLS (device: own site only), and the
-- site is re-checked explicitly.
CREATE POLICY artefacts_select_device ON artefacts FOR SELECT TO app_api
  USING (app_has_role('device') AND EXISTS (SELECT 1 FROM scans s
         WHERE s.id = artefacts.scan_id AND app_device_scoped(s.site_id)));
CREATE POLICY artefacts_insert_device ON artefacts FOR INSERT TO app_api
  WITH CHECK (app_has_role('device') AND EXISTS (SELECT 1 FROM scans s
              WHERE s.id = artefacts.scan_id AND app_device_scoped(s.site_id)));
CREATE POLICY artefacts_update_device ON artefacts FOR UPDATE TO app_api
  USING      (app_has_role('device') AND EXISTS (SELECT 1 FROM scans s
              WHERE s.id = artefacts.scan_id AND app_device_scoped(s.site_id)))
  WITH CHECK (app_has_role('device') AND EXISTS (SELECT 1 FROM scans s
              WHERE s.id = artefacts.scan_id AND app_device_scoped(s.site_id)));

-- ---------------------------------------------------------------- transition authority
-- Replaces the 0007 body (same signature, so owner and the app_api grant are kept).
-- Changes: device gets capture_pending -> quality_pending; nurse_operator/clinician get
-- quality_failed -> acquisition_failure (controller ruling for plan 02).
CREATE OR REPLACE FUNCTION scan_transition_authorized(from_s scan_status, to_s scan_status) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(CASE
    WHEN to_s = 'revoked'
      THEN app_has_role('nurse_operator') OR app_has_role('clinician')
    WHEN from_s = 'capture_pending' AND to_s = 'quality_pending'
      THEN app_has_role('nurse_operator') OR app_has_role('clinician') OR app_has_role('device')
    WHEN from_s = 'capture_pending' AND to_s = 'acquisition_failure'
      THEN app_has_role('nurse_operator') OR app_has_role('clinician')
    WHEN from_s = 'quality_failed' AND to_s IN ('capture_pending','acquisition_failure')
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
    ELSE false
  END, false)
$$;
