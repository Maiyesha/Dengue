-- Plan 02 Task 9: App Attest enrolment / assertion challenges, and the grants the server-internal
-- `system_agent` actor needs to enrol devices, advance assertion counters and store push tokens.
--
-- Device routes run their DB work inside withRls() as app.roles = 'system_agent' with
-- app.site_id = the caller's (or device's) site. Column-level grants are per Postgres role
-- (app_api), not per app role, so:
--   * writes (INSERT/UPDATE) of attest_public_key / push_token are column-granted to app_api but
--     row-limited by policy to system_agent on its own app.site_id (writing does not disclose);
--   * attest_public_key is never SELECT-granted to app_api; it is read through the SECURITY
--     DEFINER function device_attest_public_key(), which returns NULL unless the caller is
--     system_agent on the device's site. push_token stays unreadable by app_api entirely.

-- ---------------------------------------------------------------- device_challenges
-- One row per issued challenge. Only sha256(challenge) is stored. Single use: consumed by DELETE.
-- Bound to the issuing user and site. TTL 5 minutes (expires_at); expired rows are swept on issue.
CREATE TABLE device_challenges (
  challenge_hash bytea       PRIMARY KEY CHECK (octet_length(challenge_hash) = 32),
  issued_to      text        NOT NULL,
  site_id        text        NOT NULL REFERENCES sites(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  expires_at     timestamptz NOT NULL DEFAULT now() + interval '5 minutes'
);
CREATE INDEX device_challenges_expires_idx ON device_challenges (expires_at);
ALTER TABLE device_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_challenges FORCE  ROW LEVEL SECURITY;
GRANT SELECT, INSERT, DELETE ON device_challenges TO app_api;
CREATE POLICY device_challenges_system ON device_challenges FOR ALL TO app_api
  USING      (app_has_role('system_agent') AND site_id = app_site_id())
  WITH CHECK (app_has_role('system_agent') AND site_id = app_site_id());

-- ---------------------------------------------------------------- devices: system_agent writes
GRANT INSERT (site_id, ward_id, app_attest_key_id, attest_public_key) ON devices TO app_api;
GRANT UPDATE (assertion_counter, push_token, status) ON devices TO app_api;
CREATE POLICY devices_insert_system ON devices FOR INSERT TO app_api
  WITH CHECK (app_has_role('system_agent') AND site_id = app_site_id());
CREATE POLICY devices_update_system ON devices FOR UPDATE TO app_api
  USING      (app_has_role('system_agent') AND site_id = app_site_id())
  WITH CHECK (app_has_role('system_agent') AND site_id = app_site_id());

-- A device token reads only its own row (status check on every device-authenticated request).
CREATE POLICY devices_select_self ON devices FOR SELECT TO app_api
  USING (app_has_role('device') AND id::text = app_user_id() AND site_id = app_site_id());

-- ---------------------------------------------------------------- attest_public_key reader
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'device_key_owner') THEN
    CREATE ROLE device_key_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOINHERIT;
  END IF;
END $$;
GRANT SELECT (id, site_id, attest_public_key) ON devices TO device_key_owner;
CREATE POLICY devices_key_owner_read ON devices FOR SELECT TO device_key_owner USING (true);
GRANT EXECUTE ON FUNCTION app_has_role(text), app_site_id(), app_roles() TO device_key_owner;

CREATE FUNCTION device_attest_public_key(p_id uuid) RETURNS bytea
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS
$$ SELECT d.attest_public_key FROM public.devices d
    WHERE d.id = p_id AND public.app_has_role('system_agent') AND d.site_id = public.app_site_id() $$;
ALTER FUNCTION device_attest_public_key(uuid) OWNER TO device_key_owner;
REVOKE ALL ON FUNCTION device_attest_public_key(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION device_attest_public_key(uuid) TO app_api;
