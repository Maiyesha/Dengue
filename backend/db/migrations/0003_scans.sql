CREATE TYPE scan_status AS ENUM (
  'capture_pending','quality_pending','quality_passed','quality_failed',
  'feature_pending','feature_complete','acquisition_failure','partial',
  'review_pending','reviewed','flagged','excluded','archived','revoked'
);

CREATE TYPE capture_step AS ENUM (
  'identity_check','positioning','neutral_face','fingertip_ppg',
  'ocular_capture','dorsal_tongue','controlled_task','quality_result'
);

CREATE TABLE scans (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_session_id uuid NOT NULL UNIQUE,
  patient_id        uuid REFERENCES patients(id),
  site_id           text NOT NULL,
  device_id         uuid REFERENCES devices(id),
  operator_user_id  text REFERENCES app_users(id),
  captured_at       timestamptz NOT NULL,
  received_at       timestamptz DEFAULT now(),
  offline           boolean NOT NULL DEFAULT false,
  protocol_version  text NOT NULL,
  status            scan_status NOT NULL DEFAULT 'capture_pending',
  metadata          jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX scans_patient_captured_idx ON scans (patient_id, captured_at);

CREATE TABLE scan_step_attempts (
  scan_id        uuid NOT NULL REFERENCES scans(id),
  step           capture_step NOT NULL,
  attempt        smallint NOT NULL CHECK (attempt BETWEEN 1 AND 3),
  device_verdict text NOT NULL CHECK (device_verdict IN ('ACCEPT','RECAPTURE','UNABLE_TO_ACQUIRE')),
  server_verdict text,
  reason_codes   text[] DEFAULT '{}',
  PRIMARY KEY (scan_id, step, attempt)
);

CREATE TABLE artefacts (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scan_id    uuid NOT NULL REFERENCES scans(id),
  step       capture_step NOT NULL,
  attempt    smallint NOT NULL,
  kind       text NOT NULL CHECK (kind IN ('video','roi_trace','metadata')),
  size_bytes bigint,
  sha256     char(64) NOT NULL,
  object_key text NOT NULL UNIQUE,
  upload_id  text,
  status     text NOT NULL DEFAULT 'declared'
             CHECK (status IN ('declared','uploading','received_verified','rejected'))
);
CREATE INDEX artefacts_scan_idx ON artefacts (scan_id);

CREATE FUNCTION scan_transition_allowed(from_s scan_status, to_s scan_status) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN to_s = 'revoked' THEN from_s NOT IN ('archived','revoked')
    WHEN from_s = 'capture_pending'    THEN to_s IN ('quality_pending','acquisition_failure')
    WHEN from_s = 'quality_pending'    THEN to_s IN ('quality_passed','quality_failed','partial')
    WHEN from_s = 'quality_failed'     THEN to_s IN ('capture_pending','acquisition_failure')
    WHEN from_s = 'quality_passed'     THEN to_s = 'feature_pending'
    WHEN from_s = 'feature_pending'    THEN to_s = 'feature_complete'
    WHEN from_s = 'feature_complete'   THEN to_s = 'review_pending'
    WHEN from_s IN ('partial','acquisition_failure') THEN to_s = 'review_pending'
    WHEN from_s = 'review_pending'     THEN to_s IN ('reviewed','flagged','excluded')
    WHEN from_s IN ('reviewed','flagged','excluded') THEN to_s = 'archived'
    ELSE false
  END
$$;

CREATE FUNCTION scans_status_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NOT scan_transition_allowed(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'DS_STATE_001: illegal scan status transition % -> %', OLD.status, NEW.status
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER scans_status_guard BEFORE UPDATE OF status ON scans
FOR EACH ROW EXECUTE FUNCTION scans_status_guard();
