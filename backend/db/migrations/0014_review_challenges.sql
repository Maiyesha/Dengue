-- Plan 02 final-review wave, F8: server-issued WebAuthn step-up challenges for clinician review.
--
-- POST /v1/scans/{id}/review-challenge issues 32 random bytes; only sha256(challenge) is stored,
-- bound to the scan, the action, reason_code, sha256(note) and the reviewer. TTL 5 minutes.
-- POST /v1/scans/{id}/review consumes it with DELETE ... RETURNING (single use; a concurrent
-- second consumer finds no row) in its own committed transaction BEFORE verification, so a failed
-- or mismatched attempt also spends it.
CREATE TABLE review_challenges (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge_hash   bytea       NOT NULL UNIQUE CHECK (octet_length(challenge_hash) = 32),
  scan_id          uuid        NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
  site_id          text        NOT NULL REFERENCES sites(id),
  reviewer_user_id text        NOT NULL,
  action           text        NOT NULL CHECK (action IN ('confirm','flag','request_repeat','exclude')),
  reason_code      text,
  note_sha256      char(64),
  created_at       timestamptz NOT NULL DEFAULT now(),
  expires_at       timestamptz NOT NULL DEFAULT now() + interval '5 minutes'
);
CREATE INDEX review_challenges_expires_idx ON review_challenges (expires_at);
CREATE INDEX review_challenges_scan_idx ON review_challenges (scan_id);

ALTER TABLE review_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE review_challenges FORCE  ROW LEVEL SECURITY;
GRANT SELECT, INSERT, DELETE ON review_challenges TO app_api;

-- A clinician sees, creates and consumes only their own challenges, on their own site, for a
-- scan of that site.
CREATE POLICY review_challenges_owner ON review_challenges FOR ALL TO app_api
  USING (app_has_role('clinician') AND site_id = app_site_id() AND reviewer_user_id = app_user_id())
  WITH CHECK (app_has_role('clinician') AND site_id = app_site_id() AND reviewer_user_id = app_user_id()
              AND EXISTS (SELECT 1 FROM scans s WHERE s.id = review_challenges.scan_id AND s.site_id = app_site_id()));
