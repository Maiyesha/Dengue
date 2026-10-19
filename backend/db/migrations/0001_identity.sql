CREATE TYPE app_role AS ENUM (
  'nurse_operator','clinician','researcher','biostatistician',
  'admin','regulatory_reviewer','system_agent'
);

CREATE TABLE sites (
  id   text PRIMARY KEY,
  name text NOT NULL
);

CREATE TABLE wards (
  id      text PRIMARY KEY,
  site_id text NOT NULL REFERENCES sites(id)
);

CREATE TABLE app_users (
  id          text PRIMARY KEY,
  idp_subject text NOT NULL UNIQUE,
  role        app_role NOT NULL,
  site_id     text REFERENCES sites(id)
);

CREATE TABLE devices (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  site_id             text NOT NULL REFERENCES sites(id),
  ward_id             text NOT NULL REFERENCES wards(id),
  app_attest_key_id   text UNIQUE,
  attest_public_key   bytea,
  assertion_counter   bigint NOT NULL DEFAULT 0,
  status              text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
  push_token          text
);

CREATE FUNCTION app_user_id() RETURNS text LANGUAGE sql STABLE AS
$$ SELECT NULLIF(current_setting('app.user_id', true), '') $$;

CREATE FUNCTION app_roles() RETURNS text[] LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN COALESCE(current_setting('app.roles', true), '') = ''
               THEN ARRAY[]::text[]
               ELSE string_to_array(current_setting('app.roles', true), ',') END $$;

CREATE FUNCTION app_site_id() RETURNS text LANGUAGE sql STABLE AS
$$ SELECT NULLIF(current_setting('app.site_id', true), '') $$;

CREATE FUNCTION app_has_role(r text) RETURNS boolean LANGUAGE sql STABLE AS
$$ SELECT r = ANY (app_roles()) $$;

GRANT EXECUTE ON FUNCTION app_user_id(), app_roles(), app_site_id(), app_has_role(text) TO app_api;
