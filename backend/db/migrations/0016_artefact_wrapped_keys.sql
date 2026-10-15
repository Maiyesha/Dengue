-- C1 (plan 03 final review, user decision 2026-10-15): envelope encryption so the server can read uploads.
-- Each artefact's per-artefact AES-256 data key is wrapped on the device with the server KMS RSA public key
-- (RSA-OAEP, SHA-256) and declared with the artefact. The quality worker unwraps it via KMS and decrypts the
-- DSv1 object (src/crypto). No production rows exist yet, so the columns are NOT NULL without defaults.
ALTER TABLE artefacts
  ADD COLUMN wrapped_key text NOT NULL,
  ADD COLUMN key_alg     text NOT NULL CHECK (key_alg = 'RSA-OAEP-256'),
  ADD COLUMN kms_key_id  text NOT NULL;
