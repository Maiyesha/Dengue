-- Plan 02 Task 3: idempotency keys for POST routes.
-- Outside RLS by design: rows are keyed by (actor_id, method, route, key), and the API only ever
-- touches the caller's own actor_id. status_code IS NULL means the first request is in flight.
-- Rows older than 24 h are treated as absent by the API (overwritten in place on reuse).
CREATE TABLE idempotency_keys (
  actor_id     text        NOT NULL,
  method       text        NOT NULL,
  route        text        NOT NULL,
  key          uuid        NOT NULL,
  payload_hash char(64)    NOT NULL,
  owner        uuid        NOT NULL,  -- claim owner token; only the owner may store/release the claim
  status_code  int         NULL,
  response     jsonb       NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_id, method, route, key)
);
CREATE INDEX idempotency_keys_created_at_idx ON idempotency_keys (created_at);
GRANT SELECT, INSERT, UPDATE, DELETE ON idempotency_keys TO app_api;
