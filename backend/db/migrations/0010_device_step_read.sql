-- Plan 02 Task 5 (fix round 1): a device token may read the step attempts of its own site's scans,
-- so GET /v1/scans/:id shows real steps and recaptures_remaining to the capture device.
-- Read-only: devices still cannot INSERT attempts (scans and attempts are written by users).
-- Same scoping pattern as 0008: the scans sub-select runs under the device's own RLS and the
-- site is re-checked explicitly via app_device_scoped().
CREATE POLICY scan_step_attempts_select_device ON scan_step_attempts FOR SELECT TO app_api
  USING (app_has_role('device') AND EXISTS (SELECT 1 FROM scans s
         WHERE s.id = scan_step_attempts.scan_id AND app_device_scoped(s.site_id)));
