-- Plan 02 Task 8: per-site protocol flags (e.g. show_experimental_at_bedside).
-- app_api may only SELECT; site roles read their own site's rows. No API toggles flags in Phase A
-- (changes are made by migration/maintenance as the table owner).
CREATE TABLE site_protocol_flags (
  site_id    text        NOT NULL REFERENCES sites(id),
  flag       text        NOT NULL,
  enabled    boolean     NOT NULL DEFAULT false,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by text        NOT NULL,
  PRIMARY KEY (site_id, flag)
);
ALTER TABLE site_protocol_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE site_protocol_flags FORCE ROW LEVEL SECURITY;
GRANT SELECT ON site_protocol_flags TO app_api;
CREATE POLICY site_protocol_flags_select ON site_protocol_flags FOR SELECT TO app_api
  USING (app_site_scoped(site_id) OR app_reads_all());
