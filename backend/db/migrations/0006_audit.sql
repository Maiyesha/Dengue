-- Task 6: append-only, hash-chained clinical audit log (doc 05 §3.5).

CREATE TABLE clinical_audit_log (
    id              BIGSERIAL PRIMARY KEY,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    event_type      TEXT NOT NULL CHECK (event_type IN
                      ('data_access','model_decision','clinician_action',
                       'config_change','export','auth','print',
                       'device_event','view_experimental','capture_rejected_post_hoc')),
    actor_id_hash   CHAR(64) NOT NULL,
    actor_role      TEXT NOT NULL,
    patient_pseudonym TEXT NOT NULL,
    resource_type   TEXT NOT NULL,
    resource_id     TEXT NOT NULL,
    model_version   TEXT,
    risk_band       TEXT,
    inputs_hash     CHAR(64),
    outputs_hash    CHAR(64),
    outcome         TEXT NOT NULL,
    justification   TEXT,
    prev_row_hash   CHAR(64) NOT NULL,
    row_hash        CHAR(64) NOT NULL
);
REVOKE UPDATE, DELETE ON clinical_audit_log FROM PUBLIC;
CREATE RULE no_update AS ON UPDATE TO clinical_audit_log DO INSTEAD NOTHING;
CREATE RULE no_delete AS ON DELETE TO clinical_audit_log DO INSTEAD NOTHING;

-- Hash of one row. occurred_at is rendered in UTC with fixed format so the hash does not
-- depend on the session TimeZone of whoever inserts or verifies.
CREATE FUNCTION audit_compute_hash(r clinical_audit_log) RETURNS text
LANGUAGE sql STABLE AS
$$ SELECT encode(digest(concat_ws('|', r.prev_row_hash,
       to_char(r.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
       r.event_type, r.actor_id_hash, r.actor_role, r.patient_pseudonym,
       r.resource_type, r.resource_id, coalesce(r.model_version,''), coalesce(r.risk_band,''),
       coalesce(r.inputs_hash,''), coalesce(r.outputs_hash,''), r.outcome,
       coalesce(r.justification,'')), 'sha256'), 'hex') $$;

-- The id is drawn inside the lock (not by column DEFAULT) so id order == chain order.
ALTER TABLE clinical_audit_log ALTER COLUMN id DROP DEFAULT;

CREATE FUNCTION audit_chain_before_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('clinical_audit_log'));
  NEW.id := nextval('clinical_audit_log_id_seq');
  SELECT row_hash INTO NEW.prev_row_hash FROM clinical_audit_log ORDER BY id DESC LIMIT 1;
  IF NEW.prev_row_hash IS NULL THEN NEW.prev_row_hash := repeat('0', 64); END IF;
  NEW.row_hash := audit_compute_hash(NEW);
  RETURN NEW;
END $$;

CREATE TRIGGER audit_chain BEFORE INSERT ON clinical_audit_log
  FOR EACH ROW EXECUTE FUNCTION audit_chain_before_insert();

-- id of the first broken row, or NULL when the whole chain verifies.
CREATE FUNCTION audit_verify_chain() RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE
  r clinical_audit_log;
  prev text := repeat('0', 64);
BEGIN
  FOR r IN SELECT * FROM clinical_audit_log ORDER BY id LOOP
    IF r.prev_row_hash IS DISTINCT FROM prev OR r.row_hash IS DISTINCT FROM audit_compute_hash(r) THEN
      RETURN r.id;
    END IF;
    prev := r.row_hash;
  END LOOP;
  RETURN NULL;
END $$;

GRANT INSERT, SELECT ON clinical_audit_log TO app_api;
GRANT USAGE ON SEQUENCE clinical_audit_log_id_seq TO app_api;
GRANT EXECUTE ON FUNCTION audit_verify_chain() TO app_api;
