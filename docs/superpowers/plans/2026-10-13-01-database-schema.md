# DengueSense Database Schema Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Postgres migrations, row-level security and a hash-chained audit log for the iOS ward-capture app's backend.

**Architecture:** Plain SQL migrations live in `backend/db/migrations/`, applied in order by a tiny TypeScript migrator. Tests run under Vitest against a real Postgres 16 started with `embedded-postgres`, because Docker isn't available on the dev machine. RLS reads per-transaction settings (`app.user_id`, `app.roles`, `app.site_id`, `app.deidentify`), which the API sets later (plan 02).

**Tech Stack:** Node 22, TypeScript 5, `pg`, `embedded-postgres` (PG 16), Vitest, `pgcrypto`.

**Spec:** `docs/superpowers/specs/2026-10-13-ios-ward-capture-app-design.md`, with `03-data-specs.md`, `04-api-reference.md` §2.3 and `05-devops-deployment.md` §3.5.

## Global Constraints
- Postgres 16; extensions `pgcrypto` and `uuid-ossp` only.
- Every table holding participant data has RLS **enabled and forced** (`ALTER TABLE … FORCE ROW LEVEL SECURITY`).
- The app connects as role `app_api` (NOLOGIN in migrations; tests `SET ROLE app_api`). It is not a superuser and not a table owner.
- Direct identifiers live only in schema `vault`. `app_api` has **no** privileges on `vault`.
- Roles enum: `nurse_operator, clinician, researcher, biostatistician, admin, regulatory_reviewer, system_agent`.
- Every feature row has `feature_availability_timestamp timestamptz NOT NULL`.
- Audit log is append-only: UPDATE/DELETE do nothing; each row stores `prev_row_hash` and `row_hash` (SHA-256 hex, 64 chars).
- Timestamps are `timestamptz`, stored in UTC.

## Review Focus
1. **Two concurrent audit inserts** must not fork the hash chain. The test fires 20 parallel inserts, then `audit_verify_chain()` must return NULL (Task 6).
2. **A clinician with no `app.site_id` set** (missing setting) must see zero rows, not all rows. The test resets the settings and asserts count = 0 (Task 5).
3. **A researcher querying `patients` directly** instead of the de-identified view gets zero rows. The test is in Task 5.
4. **Re-running migrations** on an already-migrated DB is a no-op. The test is in Task 0.
5. **An out-of-range vital** (e.g. SpO₂ 120) is stored with `validity='INVALID'`, not rejected or dropped. The test is in Task 4.

---

### Task 0: Repo bootstrap, migrator, test harness

**Files:**
- Create: `.gitignore`, `backend/package.json`, `backend/tsconfig.json`, `backend/vitest.config.ts`
- Create: `backend/db/migrate.ts`, `backend/test/pg.ts` (global setup), `backend/test/migrate.test.ts`

**Interfaces:**
- Produces: `migrate(client: pg.Client, dir?: string): Promise<string[]>`, which returns the filenames it newly applied. Applied files are tracked in `schema_migrations(filename text primary key, applied_at timestamptz)`.
- Produces: `getTestPool(): pg.Pool`, a superuser pool to a fresh DB that has been migrated once per test run. `asRole(pool, ctx: {userId: string; roles: string[]; siteId?: string; deidentify?: boolean}, fn: (c: pg.PoolClient) => Promise<T>): Promise<T>` opens a transaction, runs `SET LOCAL ROLE app_api` and `set_config('app.*', …, true)` for each ctx field, runs fn, then rolls back.

- [ ] **Step 1:** `git init`, create branch `feat/backend-schema`, add `.gitignore` (node_modules, `.embedded-pg/`, dist).
- [ ] **Step 2:** Write `backend/test/migrate.test.ts`:
  - `applies all migrations once`: on a fresh DB, `migrate()` returns ≥1 file.
  - `is idempotent`: a second call returns `[]`.
- [ ] **Step 3:** Run `npx vitest run test/migrate.test.ts`. Expected: FAIL (module not found).
- [ ] **Step 4:** Implement `migrate` (sorted `*.sql`, each in its own transaction) and the `embedded-postgres` global setup (port 54329, data dir `.embedded-pg/`). Add `backend/db/migrations/0000_init.sql` creating the extensions and role `app_api`.
- [ ] **Step 5:** Run `npx vitest run`. Expected: PASS.
- [ ] **Step 6:** Commit: `chore(db): migrator and embedded postgres test harness`.

### Task 1: Sites, users, devices

**Files:** Create `backend/db/migrations/0001_identity.sql`, `backend/test/identity.test.ts`

**Interfaces:**
- Produces tables:
  - `sites(id text pk, name text)`
  - `wards(id text pk, site_id text fk)`
  - `app_users(id text pk, idp_subject text unique, role app_role not null, site_id text fk null)`
  - `devices(id uuid pk, site_id text fk, ward_id text fk, app_attest_key_id text unique, attest_public_key bytea, assertion_counter bigint default 0, status text check in ('active','revoked'), push_token text null)`
- Produces type `app_role` (the 7 values from Global Constraints).
- Produces SQL helper functions (STABLE):
  - `app_user_id()` returns text
  - `app_roles()` returns text[] (comma-split of `current_setting('app.roles', true)`, empty when unset)
  - `app_site_id()` returns text
  - `app_has_role(r text)` returns bool

- [ ] **Step 1:** Write tests:
  - `app_roles() returns {} when unset`
  - `app_roles() parses 'clinician,admin'`
  - `devices.status rejects 'lost'` (check violation)
  - `app_users.role rejects 'nurse'` (invalid enum)
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Write the migration.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(db): sites, users, devices, rls helper functions`.

### Task 2: Patients, identifier vault, consent

**Files:** Create `backend/db/migrations/0002_patients_consent.sql`, `backend/test/patients.test.ts`

**Interfaces:**
- Produces:
  - `patients(id uuid pk default gen_random_uuid(), participant_code text unique not null check (participant_code ~ '^DS-[A-Z]+-[0-9]{5}$'), pseudonym_id text unique not null, site_id text fk not null, ward_id text fk, bed_label text, cohort text, status text check in ('active','deteriorated','discharged','excluded'), created_at)`
- Produces `vault.patient_identifiers(patient_id uuid pk fk, ciphertext bytea not null, dek_wrapped bytea not null, kek_id text not null)`. Encryption happens in the app layer; the DB stores ciphertext only.
- Produces:
  - `consent_versions(version text pk, is_current bool)`
  - `consents(id uuid pk, patient_id fk, consent_version text fk, primary_research bool not null, secondary_use bool, international_transfer bool, consented_at timestamptz not null, withdrawn_at timestamptz null)`
- Produces view `patient_consent_status(patient_id, primary_research, consent_version, current_version, withdrawn)`, taken from the latest consent per patient.

- [ ] **Step 1:** Write tests:
  - `participant_code rejects 'NMRR-2026-00123'`
  - `app_api cannot select vault.patient_identifiers`: expect error code `42501`
  - `consent status shows superseded`: consent v1 exists while v2 is current, so `consent_version='v1'` and `current_version='v2'`
  - `withdrawn consent sets withdrawn=true`
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Write the migration (revoke all on schema `vault` from `app_api`, PUBLIC).
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(db): patients, identifier vault, consent status`.

### Task 3: Scans, steps, artefacts, review states

**Files:** Create `backend/db/migrations/0003_scans.sql`, `backend/test/scans.test.ts`

**Interfaces:**
- Produces enum `scan_status`:
  - `capture_pending, quality_pending, quality_passed, quality_failed, feature_pending, feature_complete, acquisition_failure, partial, review_pending, reviewed, flagged, excluded, archived, revoked`
- Produces enum `capture_step`:
  - `identity_check, positioning, neutral_face, fingertip_ppg, ocular_capture, dorsal_tongue, controlled_task, quality_result`
- Produces:
  - `scans(id uuid pk, client_session_id uuid unique not null, patient_id fk, site_id text not null, device_id uuid fk, operator_user_id text fk, captured_at timestamptz not null, received_at timestamptz default now(), offline bool not null default false, protocol_version text not null, status scan_status not null default 'capture_pending', metadata jsonb not null default '{}')`
  - Index on `(patient_id, captured_at)`.
  - `scan_step_attempts(scan_id fk, step capture_step, attempt smallint check (attempt between 1 and 3), device_verdict text check in ('ACCEPT','RECAPTURE','UNABLE_TO_ACQUIRE'), server_verdict text null, reason_codes text[] default '{}', primary key (scan_id, step, attempt))`
  - `artefacts(id uuid pk, scan_id fk, step capture_step, attempt smallint, kind text check in ('video','roi_trace','metadata'), size_bytes bigint, sha256 char(64) not null, object_key text unique not null, upload_id text, status text check in ('declared','uploading','received_verified','rejected') default 'declared')`
- Produces function `scan_transition_allowed(from scan_status, to scan_status) returns bool`, plus a trigger that raises `DS_STATE_001` on any disallowed status change. Allowed transitions:
  - `capture_pending→quality_pending|acquisition_failure|revoked`
  - `quality_pending→quality_passed|quality_failed|partial`
  - `quality_failed→capture_pending|acquisition_failure`
  - `quality_passed→feature_pending`
  - `feature_pending→feature_complete`
  - `feature_complete→review_pending`
  - `partial|acquisition_failure→review_pending`
  - `review_pending→reviewed|flagged|excluded`
  - `reviewed|flagged|excluded→archived`
  - any non-archived state → `revoked`

- [ ] **Step 1:** Write tests:
  - `client_session_id is unique`
  - `attempt 4 is rejected`
  - `capture_pending→feature_pending raises DS_STATE_001`
  - `review_pending→reviewed allowed`
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Write the migration.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(db): scans, step attempts, artefacts, state machine`.

### Task 4: Clinical observations, labs, quality, features, reviews

**Files:** Create `backend/db/migrations/0004_clinical_quality_features.sql`, `backend/test/clinical.test.ts`

**Interfaces:**
- Produces `clinical_observations(observation_id uuid pk, patient_id fk, scan_client_session_id uuid null, observer_user_id text, measured_at timestamptz not null, recorded_at timestamptz default now(), vital text check in ('hr','spo2','sbp','dbp','temp_c','rr','crt_s'), value numeric not null, source_device_type text not null, validity text not null)`. A BEFORE INSERT trigger sets `validity` to `'VALID'` or `'INVALID'` using these ranges:
  - hr 30–220
  - spo2 50–100
  - sbp 40–250
  - dbp 20–150
  - temp_c 32–42
  - rr 4–60
  - crt_s 0–10
- Produces `lab_values(id uuid pk, patient_id fk, test text check in ('haemoglobin','haematocrit','wbc_count','platelet_count'), value numeric, unit text, collected_at timestamptz not null, methodology text not null)`.
- Produces `sqi_checks(scan_id fk, step capture_step, attempt smallint, check_id text check in ('face_detection','motion_headpose','exposure_lighting','framerate_compression','rppg_snr','occlusion','ocular_segmentation','tongue_segmentation','duration_missing_frames','fingertip_coverage'), source text check in ('device','server'), passed bool, metric_value numeric, threshold numeric, reason_code text)`.
- Produces `features(scan_id fk, domain text check in ('rppg_face','rppg_fingertip','facial','ocular','tongue_oral'), name text, value numeric, pipeline_version text not null, feature_availability_timestamp timestamptz not null, tier text not null default 'experimental' check (tier='experimental'), primary key (scan_id, domain, name, pipeline_version))`.
- Produces `scan_reviews(id uuid pk, scan_id fk, reviewer_user_id text, action text check in ('confirm','flag','request_repeat','exclude'), reason_code text, note text, webauthn_assertion_hash char(64) not null, created_at)`.

- [ ] **Step 1:** Write tests:
  - `spo2 120 stored with validity INVALID`
  - `hr 88 stored VALID`
  - `feature without availability timestamp rejected`
  - `feature tier 'validated' rejected`
  - `sqi_checks accepts fingertip_coverage`
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Write the migration.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(db): observations, labs, quality checks, features, reviews`.

### Task 5: Row-level security policies

**Files:** Create `backend/db/migrations/0005_rls.sql`, `backend/test/rls.test.ts`, `backend/test/fixtures.ts` (seed: sites A and B, one patient per site, one scan each, one user per role)

**Interfaces:**
- Grants `app_api` SELECT/INSERT/UPDATE as each policy needs; never DELETE on clinical tables.
- Produces view `research_patients` (`security_barrier`, owned by a definer role): `pseudonym_id, cohort, status, site_bucket` (the site id's first segment). No participant_code, no bed.
- Policy rules (per doc 04 §2.3):
  - **`nurse_operator` and `clinician`:** rows where `site_id = app_site_id()`.
  - **`researcher` and `biostatistician`:** no direct rows on `patients`. Read scans, features and sqi_checks across sites, but only through `research_*` views.
  - **`admin` and `regulatory_reviewer`:** read all.
  - **`system_agent`:** read and update `scans`, `artefacts`, `sqi_checks` and `features`.
  - **`scan_reviews` INSERT:** `clinician` only.

- [ ] **Step 1:** Write tests (use `asRole`):
  - `clinician site A sees 1 patient, not site B`
  - `clinician with no site setting sees 0 patients`
  - `nurse_operator cannot insert scan_reviews` (42501 or RLS violation)
  - `researcher selecting patients sees 0 rows`
  - `researcher sees research_patients without participant_code column`
  - `admin sees both patients`
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Write the policies.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(db): row level security per role and site`.

### Task 6: Hash-chained clinical audit log

**Files:** Create `backend/db/migrations/0006_audit.sql`, `backend/test/audit.test.ts`

**Interfaces:**
- Produces `clinical_audit_log`, exactly as in doc 05 §3.5. Its `event_type` CHECK is extended with `'device_event'`, `'view_experimental'` and `'capture_rejected_post_hoc'`.
- A BEFORE INSERT trigger takes `pg_advisory_xact_lock(hashtext('clinical_audit_log'))`. It sets `prev_row_hash` to the latest `row_hash`, or 64 `'0'` characters for the first row. It then sets `row_hash` with `encode(digest(concat_ws('|', prev_row_hash, occurred_at, event_type, actor_id_hash, actor_role, patient_pseudonym, resource_type, resource_id, coalesce(model_version,''), coalesce(risk_band,''), coalesce(inputs_hash,''), coalesce(outputs_hash,''), outcome, coalesce(justification,'')),'sha256'),'hex')`.
- Produces `audit_verify_chain() returns bigint`, the id of the first broken row, or NULL.
- `app_api` has INSERT and SELECT only. Rules `no_update` and `no_delete` are as in doc 05.

- [ ] **Step 1:** Write tests:
  - `update is a no-op`: a row's outcome is unchanged after UPDATE
  - `delete is a no-op`
  - `chain verifies after 50 inserts`: verify returns NULL
  - `20 concurrent inserts keep chain valid`
  - `tampering detected`: as superuser, disable rule `no_update`, change one row, re-enable, then verify returns that id
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Write the migration.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(db): append-only hash-chained clinical audit log`.

## Verification (plan complete)
Run `cd backend && npx vitest run`. Expected: all suites pass, zero skipped.
