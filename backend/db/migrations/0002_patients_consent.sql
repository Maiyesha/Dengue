CREATE TABLE patients (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_code text NOT NULL UNIQUE CHECK (participant_code ~ '^DS-[A-Z]+-[0-9]{5}$'),
  pseudonym_id     text NOT NULL UNIQUE,
  site_id          text NOT NULL REFERENCES sites(id),
  ward_id          text REFERENCES wards(id),
  bed_label        text,
  cohort           text,
  status           text NOT NULL DEFAULT 'active'
                   CHECK (status IN ('active','deteriorated','discharged','excluded')),
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- Direct identifiers: ciphertext only (encrypted in the app layer). No app_api access.
CREATE SCHEMA vault;
REVOKE ALL ON SCHEMA vault FROM PUBLIC;
REVOKE ALL ON SCHEMA vault FROM app_api;

CREATE TABLE vault.patient_identifiers (
  patient_id  uuid PRIMARY KEY REFERENCES patients(id),
  ciphertext  bytea NOT NULL,
  dek_wrapped bytea NOT NULL,
  kek_id      text NOT NULL
);
REVOKE ALL ON ALL TABLES IN SCHEMA vault FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA vault FROM app_api;

CREATE TABLE consent_versions (
  version    text PRIMARY KEY,
  is_current boolean NOT NULL DEFAULT false
);

CREATE TABLE consents (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id            uuid NOT NULL REFERENCES patients(id),
  consent_version       text NOT NULL REFERENCES consent_versions(version),
  primary_research      boolean NOT NULL,
  secondary_use         boolean,
  international_transfer boolean,
  consented_at          timestamptz NOT NULL,
  withdrawn_at          timestamptz
);
CREATE INDEX consents_patient_idx ON consents (patient_id, consented_at DESC);

-- Latest consent per patient; security_invoker so Task 5 RLS applies to the caller.
CREATE VIEW patient_consent_status WITH (security_invoker = true) AS
SELECT DISTINCT ON (c.patient_id)
       c.patient_id,
       c.primary_research,
       c.consent_version,
       (SELECT v.version FROM consent_versions v WHERE v.is_current ORDER BY v.version DESC LIMIT 1) AS current_version,
       (c.withdrawn_at IS NOT NULL) AS withdrawn
FROM consents c
ORDER BY c.patient_id, c.consented_at DESC, c.id;
