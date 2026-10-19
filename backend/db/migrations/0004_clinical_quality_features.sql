-- Task 4: clinical observations, labs, quality checks, features, reviews.
-- RLS is applied in a later migration.

CREATE TABLE clinical_observations (
  observation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid NOT NULL REFERENCES patients(id),
  scan_client_session_id uuid NULL,
  observer_user_id text NOT NULL,
  measured_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  vital text NOT NULL CHECK (vital IN ('hr','spo2','sbp','dbp','temp_c','rr','crt_s')),
  value numeric NOT NULL,
  source_device_type text NOT NULL,
  validity text NOT NULL DEFAULT 'VALID' CHECK (validity IN ('VALID','INVALID'))
);
CREATE INDEX clinical_observations_patient_idx ON clinical_observations(patient_id, measured_at);

CREATE FUNCTION clinical_observations_set_validity() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE lo numeric; hi numeric;
BEGIN
  SELECT r.lo, r.hi INTO lo, hi FROM (VALUES
    ('hr',30,220),('spo2',50,100),('sbp',40,250),('dbp',20,150),
    ('temp_c',32,42),('rr',4,60),('crt_s',0,10)
  ) AS r(v, lo, hi) WHERE r.v = NEW.vital;
  IF NEW.value >= lo AND NEW.value <= hi THEN
    NEW.validity := 'VALID';
  ELSE
    NEW.validity := 'INVALID';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER clinical_observations_validity
  BEFORE INSERT ON clinical_observations
  FOR EACH ROW EXECUTE FUNCTION clinical_observations_set_validity();

CREATE TABLE lab_values (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid NOT NULL REFERENCES patients(id),
  test text NOT NULL CHECK (test IN ('haemoglobin','haematocrit','wbc_count','platelet_count')),
  value numeric,
  unit text,
  collected_at timestamptz NOT NULL,
  methodology text NOT NULL
);
CREATE INDEX lab_values_patient_idx ON lab_values(patient_id, collected_at);

CREATE TABLE sqi_checks (
  scan_id uuid NOT NULL REFERENCES scans(id),
  step capture_step NOT NULL,
  attempt smallint NOT NULL,
  check_id text NOT NULL CHECK (check_id IN ('face_detection','motion_headpose','exposure_lighting','framerate_compression','rppg_snr','occlusion','ocular_segmentation','tongue_segmentation','duration_missing_frames','fingertip_coverage')),
  source text NOT NULL CHECK (source IN ('device','server')),
  passed boolean NOT NULL,
  metric_value numeric,
  threshold numeric,
  reason_code text
);
CREATE INDEX sqi_checks_scan_idx ON sqi_checks(scan_id, step, attempt);

CREATE TABLE features (
  scan_id uuid NOT NULL REFERENCES scans(id),
  domain text NOT NULL CHECK (domain IN ('rppg_face','rppg_fingertip','facial','ocular','tongue_oral')),
  name text NOT NULL,
  value numeric,
  pipeline_version text NOT NULL,
  feature_availability_timestamp timestamptz NOT NULL,
  tier text NOT NULL DEFAULT 'experimental' CHECK (tier = 'experimental'),
  PRIMARY KEY (scan_id, domain, name, pipeline_version)
);

CREATE TABLE scan_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scan_id uuid NOT NULL REFERENCES scans(id),
  reviewer_user_id text NOT NULL,
  action text NOT NULL CHECK (action IN ('confirm','flag','request_repeat','exclude')),
  reason_code text,
  note text,
  webauthn_assertion_hash char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX scan_reviews_scan_idx ON scan_reviews(scan_id);
