-- Plan 02 final-review wave, F9(a): artefact declare creates the scan_step_attempts row when it is
-- missing (POST /v1/scans pre-registration sends no device_attempts), and the capture device
-- itself declares artefacts with its device token. A `device` session may therefore INSERT step
-- attempts for scans of its own site. Still no UPDATE/DELETE for anyone (attempts are append-only)
-- and attempt stays CHECKed to 1..3 by 0003.
CREATE POLICY scan_step_attempts_insert_device ON scan_step_attempts FOR INSERT TO app_api
  WITH CHECK (app_has_role('device') AND EXISTS (SELECT 1 FROM scans s
              WHERE s.id = scan_step_attempts.scan_id AND app_device_scoped(s.site_id)));
