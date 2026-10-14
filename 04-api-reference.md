# API Reference & Interface Integration Guide

**Document:** 04 — API Reference & Interface Integration Guide
**Programme:** beAIve DengueSense (reAInmaker SDN BHD)
**Source Frameworks:** Vibe Coding v2.0 (§2.5 Backend Schema, §8.2 Backend Starter Prompt, §8.4 Database Schema Prompt, §8.5 Auth Setup Prompt, §4.2 Non-Functional Requirements) and beAIve DengueSense v2.1 (§4.1 Functional Modules, §8.3 Privacy & Security Baseline, §11 Governance & RACI).
**Audience:** Backend engineers, ML platform integrators, agentic-workflow authors, security reviewers, regulatory reviewers.
**Status:** Research Use Only — endpoints are reference specifications for the G1→G7 build phase; no clinical decision-support claim attaches to the API surface until gate G7 passes.

---

## 1. Endpoints & Methods: Complete CRUD Specifications

### 1.1 Design Conventions

The beAIve DengueSense REST API exposes a versioned surface at `https://api.denguesense.{tld}/v1/`. Every resource is identified by a URL-safe UUID v4. All request and response bodies are `application/json; charset=utf-8`, except media uploads which use `multipart/form-data` against pre-signed object-storage URLs (Vibe Coding §2.5 file-storage pattern: `/captures/{patient_id}/{scan_id}/`). All list endpoints honour `?limit=` (max 200), `?cursor=` (opaque forward-only token), `?sort=field:asc|desc`, and field-projection via `?fields=`. Time fields are RFC 3339 UTC. Money, units, and clinical coding systems (LOINC, SNOMED CT, ICD-10) follow the data spec in Doc 03.

Every mutating request **must** carry an `Idempotency-Key` header (UUID v4) so retries after transient network failure cannot create duplicate clinical records. The server stores a 24-hour idempotency fingerprint keyed by `(user_id, method, route, Idempotency-Key)`. Non-idempotent clinical writes (e.g. `POST /patients/{id}/clinical-data` with a new observation timestamp) explicitly opt out of automatic retry at the client SDK level.

### 1.2 Endpoint Summary Table

The complete API surface is enumerated below. Methods in **bold** are primary; lower-case method names indicate the action flavour (e.g. recapture). All paths are relative to `/v1`.

| # | Method | Path | Resource Group | RBAC Roles | Idempotent |
|---|--------|------|-----------------|------------|------------|
| 1 | POST | `/auth/login` | Authentication | public | Yes (key) |
| 2 | POST | `/auth/refresh` | Authentication | any valid refresh token | Yes (key) |
| 3 | POST | `/auth/logout` | Authentication | any valid token | Yes |
| 4 | GET | `/auth/me` | Authentication | clinician, researcher, biostatistician, admin, regulatory_reviewer, system_agent | — |
| 5 | POST | `/patients` | Patients & Cohorts | clinician, admin | Yes (key) |
| 6 | GET | `/patients/{id}` | Patients & Cohorts | clinician, researcher (de-identified), biostatistician (de-identified), admin, regulatory_reviewer | — |
| 7 | GET | `/patients` | Patients & Cohorts | clinician, researcher, biostatistician, admin, regulatory_reviewer | — |
| 8 | PATCH | `/patients/{id}` | Patients & Cohorts | clinician (own site), admin | — |
| 9 | POST | `/scans` | Scan Sessions | clinician, system_agent | Yes (key) |
| 10 | GET | `/scans/{id}` | Scan Sessions | clinician, researcher, biostatistician, admin, regulatory_reviewer | — |
| 11 | GET | `/scans` | Scan Sessions | clinician, researcher, biostatistician, admin | — |
| 12 | DELETE | `/scans/{id}` | Scan Sessions | admin (soft delete only) | — |
| 13 | POST | `/scans/{id}/recapture` | Scan Sessions | clinician, system_agent | Yes (key) |
| 14 | POST | `/scans/{id}/features/extract` | Feature Extraction | system_agent, biostatistician (read-only jobs) | Yes (key) |
| 15 | GET | `/scans/{id}/features` | Feature Extraction | clinician, researcher, biostatistician, regulatory_reviewer | — |
| 16 | POST | `/assessments` | Risk Assessment | clinician, system_agent | Yes (key) |
| 17 | GET | `/assessments/{id}` | Risk Assessment | clinician, researcher, biostatistician, regulatory_reviewer, admin | — |
| 18 | GET | `/patients/{id}/assessments` | Risk Assessment | clinician, researcher, biostatistician, regulatory_reviewer | — |
| 19 | POST | `/scans/{id}/quality-check` | Quality Gate | system_agent, clinician (read) | Yes (key) |
| 20 | GET | `/quality/reason-codes` | Quality Gate | clinician, researcher, biostatistician, regulatory_reviewer | — |
| 21 | POST | `/patients/{id}/clinical-data` | Clinical Data | clinician, system_agent | Yes (key) |
| 22 | GET | `/patients/{id}/clinical-data` | Clinical Data | clinician, researcher, biostatistician, regulatory_reviewer | — |
| 23 | GET | `/audit/logs` | Audit & Compliance | admin, regulatory_reviewer | — |
| 24 | GET | `/audit/decisions/{id}` | Audit & Compliance | admin, regulatory_reviewer, clinician (own decisions) | — |
| 25 | GET | `/dashboard/summary` | Research Dashboard | researcher, biostatistician, admin, regulatory_reviewer | — |
| 26 | GET | `/dashboard/subgroups` | Research Dashboard | researcher, biostatistician, admin, regulatory_reviewer | — |
| 27 | GET | `/admin/users` | Admin | admin | — |
| 28 | POST | `/admin/users` | Admin | admin | Yes (key) |
| 29 | PATCH | `/admin/users/{id}/roles` | Admin | admin | — |

### 1.3 Authentication & Sessions

#### POST /auth/login

Authenticate a user with email + password (or MFA challenge token issued by the upstream IdP — Clerk/Supabase Auth per Vibe Coding §8.5). Returns a short-lived JWT access token and a long-lived refresh token bound to the device fingerprint.

**Request**
```json
POST /v1/auth/login
Content-Type: application/json
Idempotency-Key: 9c7e3a21-8b50-4d2d-9b3a-2f8b1c4d5e6f

{
  "email": "dr.tan@hospitalA.moh.gov.my",
  "password": "********",
  "mfa_challenge_response": "034178",
  "device_fingerprint": "sha256:9f4b...e21c",
  "context": {
    "site_id": "site-ukm-001",
    "client_ip": "10.20.30.40",
    "user_agent": "DengueSense-Capture/1.4.2"
  }
}
```

**Response 200 OK**
```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIsImtpZCI6...",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "rt_8d3f...e21c",
  "refresh_expires_in": 604800,
  "user": {
    "id": "usr_01HXKE...",
    "email": "dr.tan@hospitalA.moh.gov.my",
    "display_name": "Dr Tan Mei Ling",
    "roles": ["clinician"],
    "site_id": "site-ukm-001",
    "mfa_enrolled": true,
    "last_login_at": "2026-08-12T07:21:03Z"
  },
  "session": {
    "id": "sess_01HX...",
    "issued_at": "2026-08-12T07:21:03Z",
    "rotated_from": null
  }
}
```

**Status codes:** `200 OK`, `400 BAD_REQUEST` (malformed payload), `401 UNAUTHORIZED` (bad credentials), `403 FORBIDDEN` (account locked, MFA required), `429 TOO_MANY_REQUESTS` (rate-limited).

#### POST /auth/refresh

Exchange a valid refresh token for a new access/refresh pair. Refresh tokens are single-use and rotate on every call; the prior token is added to a denylist for the remainder of its TTL (Vibe Coding §8.5 protected-route requirement).

**Request**
```json
POST /v1/auth/refresh
{ "refresh_token": "rt_8d3f...e21c", "device_fingerprint": "sha256:9f4b...e21c" }
```
**Response 200 OK** — identical schema to `/auth/login` with `session.rotated_from` populated.
**Status codes:** `200 OK`, `401 UNAUTHORIZED` (expired/revoked/replayed token — triggers full re-login).

#### POST /auth/logout

Invalidates the supplied access token (and revokes the refresh token) and writes a `session.end` audit event. Returns `204 No Content`. Status: `204`, `401`.

#### GET /auth/me

Returns the calling user's profile, active roles, site binding, and capability list. Used by clients to bootstrap the UI after a cold start.

**Response 200 OK**
```json
{
  "user": {
    "id": "usr_01HXKE...",
    "email": "dr.tan@hospitalA.moh.gov.my",
    "display_name": "Dr Tan Mei Ling",
    "roles": ["clinician"],
    "site_id": "site-ukm-001",
    "site_name": "Hospital Canselor Tuanku Muhriz, UKM",
    "cohort_assignments": ["dws", "dws"], 
    "capabilities": ["scan:create", "patient:read:own_site", "assessment:run", "audit:read:own"],
    "mfa_enrolled": true,
    "last_access_review_at": "2026-07-01T00:00:00Z"
  }
}
```

### 1.4 Patients & Cohorts

#### POST /patients

Creates a new patient record under the caller's site. Direct identifiers (name, NRIC, MRN) are written to the `patient_identifiers` table that is field-level encrypted and reachable only by the linking service; clinical and research tables hold a `patient_pseudonym_id` (Vibe Coding §2.5 sensitive-fields pattern; DengueSense §8.3 direct-identifier separation mandate).

**Request**
```json
POST /v1/patients
Authorization: Bearer eyJ...
Idempotency-Key: 3b8c1d7e-9f2a-4b6c-8d1e-2f3a4b5c6d7e

{
  "site_id": "site-ukm-001",
  "study_id": "NMRR-2026-00123",
  "cohort": "dengue_with_warning_signs",
  "consent": {
    "consent_id": "cons_01HX...",
    "consented_at": "2026-08-12T06:00:00Z",
    "consent_version": "v3.2-2026-06"
  },
  "direct_identifiers": {
    "mrn": "MRN-UKM-558821",
    "nric_hash": "sha256:8f1a...",
    "initials": "TML",
    "date_of_birth": "1987-03-14",
    "sex": "female"
  },
  "registration_context": {
    "day_of_illness": 3,
    "enrolling_clinician_id": "usr_01HXKE..."
  }
}
```

**Response 201 Created**
```json
{
  "patient": {
    "id": "pat_01HXKF2Q7...",
    "patient_pseudonym_id": "psd_8d3f...e21c",
    "site_id": "site-ukm-001",
    "cohort": "dengue_with_warning_signs",
    "status": "active",
    "consent_id": "cons_01HX...",
    "created_at": "2026-08-12T07:31:18Z"
  }
}
```
**Status codes:** `201 CREATED`, `400 BAD_REQUEST`, `401`, `403` (role not permitted or wrong site), `409 CONFLICT` (duplicate MRN/consent).

#### GET /patients/{id}

Returns a single patient record. For callers in the `researcher` or `biostatistician` role, the server strips direct identifiers, returns `patient_pseudonym_id` only, and rewrites `site_id` to a `site_bucket` (small bucket to prevent re-identification per §8.3 pseudonymisation).

**Response 200 OK** — object as above plus `enrollment`, `latest_assessment_id`, `latest_scan_id`, `cohort_flow` array.
**Status codes:** `200`, `401`, `403` (cross-site access for clinician), `404 NOT_FOUND`, `410 GONE` (record purged under retention rule).

#### GET /patients

List endpoint with filters. Supports `?cohort=`, `?site_id=`, `?status=active|deteriorated|discharged|excluded`, `?enrolled_after=`, `?enrolled_before=`, `?consent_version=`. For non-admin roles the server silently applies an RLS filter (see §2.3) so callers cannot exfiltrate records outside their permitted cohort/site envelope.

**Response 200 OK**
```json
{
  "items": [ { "id": "pat_01HXKF2Q7...", "patient_pseudonym_id": "psd_8d3f...", "cohort": "dws", "status": "active", "site_bucket": "ukm", "created_at": "2026-08-12T07:31:18Z" } ],
  "page": { "limit": 50, "cursor": "eyJpZCI6InBhdF8wMUhYS0tG...", "has_more": true, "total_count_classified": true },
  "rls_envelope": { "site_scope": "site-ukm-001", "cohort_scope": "*", "deidentify": false }
}
```

#### PATCH /patients/{id}

Partial update to status (active → deteriorated | discharged | excluded), discharge timestamp, or cohort re-assignment (with audit reason). Direct identifier edits are routed via a separate, more strongly-authenticated `/patients/{id}/identities` endpoint outside the v1 surface. Status codes: `200`, `400`, `401`, `403`, `404`, `409`.

### 1.5 Scan Sessions

#### POST /scans

Initiates a capture session. The caller (clinician UI or `system_agent`) supplies the patient id, intended capture type (`face`, `ocular`, `tongue`, `multi`), device profile, and ambient metadata. The server returns a `scan_id`, the pre-signed upload URLs for each modality segment, and a `session_token` used to authenticate the real-time guidance websocket (out of scope for this REST spec).

**Request**
```json
POST /v1/scans
Idempotency-Key: 7f3e2c1d-8b4a-4d9c-9e1f-2a3b4c5d6e7f
{
  "patient_id": "pat_01HXKF2Q7...",
  "capture_type": "multi",
  "device_profile": { "model": "Pixel 8 Pro", "os": "Android 14", "camera_app": "DengueSense-Capture/1.4.2", "framerate_fps": 30, "resolution": "1920x1080" },
  "ambient": { "site_id": "site-ukm-001", "operator_id": "usr_01HXKE...", "room_lighting_lux": 410, "distance_cm_hint": 50 }
}
```

**Response 201 Created**
```json
{
  "scan": {
    "id": "scn_01HXKG3A8...",
    "patient_id": "pat_01HXKF2Q7...",
    "status": "capture_pending",
    "capture_type": "multi",
    "created_at": "2026-08-12T07:42:11Z",
    "upload_targets": [
      { "modality": "face", "segment": "face_front_30s", "presigned_put_url": "https://obj.denguesense.{tld}/captures/pat_01HX.../scn_01HX.../face_front_30s?sig=...", "expires_in": 900 },
      { "modality": "ocular", "segment": "ocular_right_10s", "presigned_put_url": "https://obj.../ocular_right_10s?sig=...", "expires_in": 900 },
      { "modality": "tongue", "segment": "tongue_dorsal_5s", "presigned_put_url": "https://obj.../tongue_dorsal_5s?sig=...", "expires_in": 900 }
    ],
    "guidance_ws_url": "wss://ws.denguesense.{tld}/v1/scans/scn_01HXKG3A8.../guidance?token=...",
    "max_recaptures_remaining": 2
  }
}
```
**Status codes:** `201`, `400`, `401`, `403`, `409` (already-active scan for patient in last 30 minutes), `422` (consent version superseded).

#### GET /scans/{id}

Returns scan metadata, status (`capture_pending|quality_pending|quality_passed|quality_failed|feature_pending|feature_complete|assessment_pending|complete|acquisition_failure`), quality verdict, feature summary, and assessment reference. Status codes: `200`, `401`, `403`, `404`.

#### GET /scans

List endpoint with filters `?patient_id=`, `?site_id=`, `?status=`, `?created_after=`, `?capture_type=`. Paginated as in §1.4.

#### DELETE /scans/{id}

Soft delete only — sets `status=revoked`, `revoked_by`, `revoked_reason`, and `revoked_at`. The underlying object-storage payloads are retained for the regulatory retention window and the audit trail is preserved. Hard delete is a separate `POST /admin/retention/purge` operation gated on `regulatory_reviewer` + `admin` dual approval. Status codes: `204`, `401`, `403`, `404`.

#### POST /scans/{id}/recapture

When the Signal-Quality Engine emits a reason code requiring a re-shoot (e.g. `DS_QG_001` motion, `DS_QG_002` lighting — see §3.4), the clinician (or the autonomous capture agent) calls this endpoint to mint a fresh `upload_targets` set and a new `attempt_number`. The prior attempt is retained in the audit trail but excluded from downstream feature extraction. Maximum recapture count is enforced server-side; exceeding it forces the scan into `acquisition_failure` per §8.3's "system records an acquisition failure rather than forcing a result" mandate.

**Request**
```json
POST /v1/scans/scn_01HXKG3A8.../recapture
Idempotency-Key: 1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d
{ "trigger_reason_code": "DS_QG_001", "trigger_detail": "head pose yaw exceeded 18 deg", "operator_id": "usr_01HXKE..." }
```

**Response 201 Created** — schema identical to `POST /scans` response but with `attempt_number: 2`, `max_recaptures_remaining: 1`, and `prior_attempt_id` populated.

### 1.6 Feature Extraction

#### POST /scans/{id}/features/extract

Triggers the agentic pipeline that runs the SQI → rPPG → Facial Perfusion → Ocular → Tongue feature extractors on the captured segments. Executed by the `system_agent` role (no human token allowed) and is the canonical machine-to-machine call described by the Vibe Coding §8.2 "smallest working backend" principle: minimal payload, full state machine on the server, traceable job handle returned.

**Request**
```json
POST /v1/scans/scn_01HXKG3A8.../features/extract
Authorization: Bearer eyJ...   (system_agent token, mTLS-pinned)
Idempotency-Key: 6b5a4c3d-2e1f-4a6b-9c8d-7e6f5a4b3c2d
{ "extractor_pipeline": ["sqi", "rppg", "facial_perfusion", "ocular", "tongue"], "feature_set_version": "fs-2026.07-lock" }
```

**Response 202 Accepted**
```json
{
  "job": {
    "id": "job_01HXKG4B9...",
    "scan_id": "scn_01HXKG3A8...",
    "status": "queued",
    "feature_set_version": "fs-2026.07-lock",
    "submitted_at": "2026-08-12T07:43:55Z",
    "eta_seconds": 35,
    "result_url": "https://api.denguesense.{tld}/v1/scans/scn_01HXKG3A8.../features"
  }
}
```
**Status codes:** `202 ACCEPTED`, `400`, `401`, `403`, `404`, `409 CONFLICT` (a job is already running), `422 UNPROCESSABLE_ENTITY` (scan not in `quality_passed` state).

#### GET /scans/{id}/features

Returns the extracted feature vector bundle. Clinicians see a compact clinical-projection; researchers and biostatisticians see the full feature matrix with `feature_availability_timestamp` per predictor (DengueSense §6 anti-leakage mandate). Regulatory reviewers see an immutable snapshot hash.

**Response 200 OK**
```json
{
  "scan_id": "scn_01HXKG3A8...",
  "feature_set_version": "fs-2026.07-lock",
  "extracted_at": "2026-08-12T07:44:30Z",
  "features": {
    "rppg": {
      "heart_rate_bpm": 92.4,
      "inter_beat_interval_ms": 649.4,
      "hrv_rmssd_ms": 28.1,
      "ac_dc_ratio": 0.0142,
      "signal_snr_db": 8.4,
      "signal_spectral_plausibility": 0.91,
      "feature_availability_timestamp": "2026-08-12T07:42:11Z"
    },
    "facial_perfusion": {
      "forehead_intensity": 0.62, "cheek_left_intensity": 0.58, "cheek_right_intensity": 0.55,
      "asymmetry_index": 0.04, "perfusion_trend_slope": -0.011, "recovery_tau_ms": 410.0
    },
    "ocular": {
      "conjunctival_pallor_score": 0.31, "redness_index": 0.18,
      "vessel_visibility_score": 0.62, "blink_rate_per_min": 14.3,
      "segmentation_confidence": 0.88
    },
    "tongue": {
      "colour_distribution_lab": { "L": 51.2, "a": 18.7, "b": 14.3 },
      "coating_coverage": 0.42, "coating_thickness": 0.31,
      "moisture_score": 0.66, "segmentation_confidence": 0.84
    }
  },
  "snapshot_hash": "sha256:b13c...e21f",
  "rls_envelope": { "deidentify": true, "site_bucket": "ukm" }
}
```

### 1.7 Risk Assessment

#### POST /assessments

Runs the locked risk-engine model on the feature set of a given scan plus the patient's clinical data snapshot at `as_of` timestamp. The engine returns a probability, risk band (`low|intermediate|high`), uncertainty quantification (conformal interval), and the locked model card reference.

**Request**
```json
POST /v1/assessments
Idempotency-Key: 0f1e2d3c-4b5a-4968-a7c9-8b7a6c5d4e3f
{
  "patient_id": "pat_01HXKF2Q7...",
  "scan_id": "scn_01HXKG3A8...",
  "clinical_data_as_of": "2026-08-12T07:30:00Z",
  "model_card": "mc-risk-2026.07-lock",
  "horizon_hours": 24
}
```

**Response 201 Created**
```json
{
  "assessment": {
    "id": "asm_01HXKG5C0...",
    "patient_id": "pat_01HXKF2Q7...",
    "scan_id": "scn_01HXKG3A8...",
    "model_card": "mc-risk-2026.07-lock",
    "horizon_hours": 24,
    "probability": 0.273,
    "risk_band": "intermediate",
    "uncertainty": { "lower": 0.18, "upper": 0.39, "method": "conformal_icp", "alpha": 0.1 },
    "input_features_used": 18,
    "input_features_missing": 2,
    "baseline_clinical_only_probability": 0.211,
    "incremental_value_delta": 0.062,
    "computed_at": "2026-08-12T07:45:12Z",
    "regulatory_hold": false,
    "audit": { "trace_id": "trc_8b3e...e21c", "decision_id": "dec_01HXKG5C1..." }
  }
}
```
**Status codes:** `201`, `400`, `401`, `403`, `404`, `409` (existing assessment for the same scan+model+horizon), `422` (insufficient features — `DS_RISK_001`), `451 UNAVAILABLE_FOR_LEGAL_REASONS` (regulatory hold — `DS_REG_001`).

#### GET /assessments/{id}

Returns the full assessment record plus the audit decision bundle. Status codes: `200`, `401`, `403`, `404`.

#### GET /patients/{id}/assessments

Returns the time-ordered assessment history for a patient with optional `?since=` filter. Used by the Research Dashboard's longitudinal view (DengueSense §6 longitudinal-change research question).

### 1.8 Quality Gate

#### POST /scans/{id}/quality-check

Runs the Signal-Quality Engine over the uploaded segments and returns a verdict, numeric quality score, and (if failed) a reason code. Idempotent — repeated calls return the cached verdict unless the underlying segments changed.

**Request**
```json
POST /v1/scans/scn_01HXKG3A8.../quality-check
Idempotency-Key: 5d4c3b2a-1e6f-4a5b-9c8d-7e6f5a4b3c2d
{ "force_recompute": false, "quality_profile": "qp-default-2026.07" }
```

**Response 200 OK**
```json
{
  "quality": {
    "scan_id": "scn_01HXKG3A8...",
    "verdict": "fail",
    "quality_score": 0.41,
    "profile": "qp-default-2026.07",
    "checks": [
      { "name": "face_detection_stability", "passed": true,  "score": 0.92 },
      { "name": "motion_head_pose",         "passed": false, "score": 0.31, "reason_code": "DS_QG_001", "detail": "yaw exceeded 18 deg over 4.2s window" },
      { "name": "exposure_lighting",        "passed": true,  "score": 0.71 },
      { "name": "rppg_snr",                 "passed": false, "score": 0.22, "reason_code": "DS_RPPG_001", "detail": "SNR 3.1 dB < 6 dB threshold" },
      { "name": "ocular_segmentation",      "passed": true,  "score": 0.88 },
      { "name": "tongue_segmentation",     "passed": true,  "score": 0.84 }
    ],
    "next_action": "recapture",
    "max_recaptures_remaining": 1
  }
}
```
**Status codes:** `200`, `400`, `401`, `403`, `404`, `422 UNPROCESSABLE_ENTITY` (scan not in `capture_pending` state).

#### GET /quality/reason-codes

Returns the catalog of reason codes used by the SQI engine. Stable across deployments so client UIs can pre-render localised recapture guidance (DengueSense §5 — "Every rejection produces an understandable reason code and a safe recapture instruction").

```json
{ "reason_codes": [
  { "code": "DS_QG_001", "category": "motion", "title": "Excessive motion or head-pose drift", "recapture_instruction": "Ask the participant to rest their head against the headrest and recapture." },
  { "code": "DS_QG_002", "category": "lighting", "title": "Lighting outside approved range", "recapture_instruction": "Reposition the participant to face the light source; avoid backlight." },
  { "code": "DS_RPPG_001", "category": "signal", "title": "rPPG SNR below threshold", "recapture_instruction": "Increase capture duration to 30 s and ensure the face is evenly lit." },
  { "code": "DS_SEG_001", "category": "segmentation", "title": "Segmentation confidence low", "recapture_instruction": "Remove glasses/mask if safe; ensure tongue is extended per protocol." }
] }
```

### 1.9 Clinical Data

#### POST /patients/{id}/clinical-data

Appends a time-stamped clinical observation record to the patient's timeline. Direct identifiers are not allowed in this resource — the schema mirrors §8.3's "routine observations as time-aligned structured variables".

**Request**
```json
POST /v1/patients/pat_01HXKF2Q7.../clinical-data
Idempotency-Key: 4c3b2a19-8d6f-4a5b-9c8d-7e6f5a4b3c2d
{
  "observed_at": "2026-08-12T07:30:00Z",
  "observer_id": "usr_01HXKE...",
  "data": {
    "day_of_illness": 3,
    "temperature_c": 38.6,
    "bp_systolic_mmhg": 104, "bp_diastolic_mmhg": 62, "pulse_pressure_mmhg": 42,
    "respiratory_rate_per_min": 22,
    "spo2_percent": 96,
    "capillary_refill_time_s": 2.4,
    "symptoms": ["abdominal_pain", "lethargy"],
    "warning_signs": ["persistent_vomiting"],
    "labs": [
      { "test": "haemoglobin", "value": 14.8, "unit": "g/dL", "method": "cell_counter", "collected_at": "2026-08-12T05:00:00Z" },
      { "test": "platelet_count", "value": 92, "unit": "x10^9/L", "method": "cell_counter", "collected_at": "2026-08-12T05:00:00Z" }
    ]
  }
}
```
**Response 201 Created**
```json
{ "clinical_data": { "id": "cd_01HXKG6D2...", "patient_id": "pat_01HXKF2Q7...", "observed_at": "2026-08-12T07:30:00Z", "recorded_at": "2026-08-12T07:46:01Z", "audit_decision_id": "dec_01HXKG6D3..." } }
```
**Status codes:** `201`, `400`, `401`, `403`, `404`, `409`.

#### GET /patients/{id}/clinical-data

Returns the timeline with `?since=` and `?until=` filters. Researchers receive lab values rounded to the cohort-bucket precision; biostatisticians see the full-resolution training-eligible subset only.

### 1.10 Audit & Compliance

#### GET /audit/logs

Search endpoint for the immutable audit trail mandated by §8.3 ("consent, access, export, and deletion logs maintained throughout the programme lifecycle"). Supports `?actor_id=`, `?action=`, `?resource_type=`, `?from=`, `?to=`, `?trace_id=`. Records cannot be modified or deleted through the API; only the retention job (separate admin endpoint, dual approval) may purge expired records after the regulatory retention window.

**Response 200 OK (truncated)**
```json
{
  "items": [
    { "id": "aud_01HXKG7E3...", "ts": "2026-08-12T07:42:11Z", "actor_id": "usr_01HXKE...", "actor_role": "clinician", "action": "scan:create", "resource_type": "scan", "resource_id": "scn_01HXKG3A8...", "site_id": "site-ukm-001", "trace_id": "trc_8b3e...e21c", "request_id": "req_5c1f...", "outcome": "success", "ip": "10.20.30.40" }
  ],
  "page": { "limit": 100, "cursor": "eyJ0cyI6IjIwMjYtMDgtMTJUMDc6NDI6MTFaIn0=", "has_more": true }
}
```
**Status codes:** `200`, `400`, `401`, `403`.

#### GET /audit/decisions/{id}

Returns the canonical decision bundle for a clinical or operational decision — e.g. an assessment output, a recapture trigger, a consent revocation. A decision is immutable once recorded; corrections are modelled as new decisions that supersede the prior one (`supersedes` field).

### 1.11 Research Dashboard

#### GET /dashboard/summary

Cohort-level aggregate metrics for the dashboard view: enrolled counts by cohort, scan success rate, recapture rate, alert rate, false-alert rate, and median lead time before endpoint. All counts are bounded by the caller's RLS envelope (site, cohort, de-identify flags).

**Response 200 OK**
```json
{
  "summary": {
    "as_of": "2026-08-12T08:00:00Z",
    "enrolled": { "healthy_control": 18, "non_dengue_febrile": 22, "dws": 41, "dws_warning_signs": 33, "severe_dengue": 11, "deteriorated": 7 },
    "scan_success_rate": 0.93, "recapture_rate": 0.21,
    "alert_rate_per_patient_day": 0.18, "false_alert_rate_per_patient_day": 0.04,
    "median_lead_time_before_endpoint_hours": 9.5,
    "subgroup_breakdown_url": "/v1/dashboard/subgroups"
  }
}
```

#### GET /dashboard/subgroups

Returns performance and count breakdowns across the prespecified subgroup axes named in DengueSense §6 (site, device, sex, age band, skin-tone category). Cell-level suppression applies when n < pre-specified minimum to prevent re-identification.

### 1.12 Admin

#### GET /admin/users

List user accounts with role bindings, site bindings, last-login, last-access-review date, and current MFA enrollment status. Status codes: `200`, `401`, `403`.

#### POST /admin/users

Provision a new user. Requires the caller to provide a strong initial password (handled by the upstream IdP) or an OAuth invitation email. The role assignment is recorded as an audited decision and triggers an access-review reminder 90 days out.

#### PATCH /admin/users/{id}/roles

Change a user's role set. Each change is recorded in the audit trail with `actor_id`, prior role set, new role set, reason, and an effective timestamp. A role change to `regulatory_reviewer` or `system_agent` triggers an out-of-band notification to the Privacy and Security Review body (DengueSense §11 governance) for periodic access review.

**Request**
```json
PATCH /v1/admin/users/usr_01HXKF8.../roles
{ "roles": ["researcher", "biostatistician"], "reason": "role expansion per RACI review 2026-08-12", "effective_at": "2026-08-12T08:00:00Z" }
```
**Response 200 OK** — `{ "user": { "id": "usr_01HXKF8...", "roles": ["researcher", "biostatistician"], "role_history_url": "/v1/audit/logs?actor_id=usr_01HXKF8...&action=role_change" } }`

### 1.13 OpenAPI / Swagger Snippet (Scans Resource)

The following OpenAPI 3.1 fragment is the canonical machine-readable contract for the Scans resource. The full spec lives at `/openapi/v1.yaml` and is served at `https://api.denguesense.{tld}/openapi.json`.

```yaml
openapi: 3.1.0
info:
  title: beAIve DengueSense API — Scans
  version: 1.0.0
  contact: { name: DengueSense Platform Team, email: api@denguesense.example }
  license: { name: Research Use Only }
servers:
  - url: https://api.denguesense.example/v1
components:
  securitySchemes:
    bearerAuth: { type: http, scheme: bearer, bearerFormat: JWT }
    serviceMtls: { type: mutualTLS }
  schemas:
    ScanInitiateRequest:
      type: object
      required: [patient_id, capture_type, device_profile]
      properties:
        patient_id: { type: string, format: uuid }
        capture_type: { type: string, enum: [face, ocular, tongue, multi] }
        device_profile: { $ref: '#/components/schemas/DeviceProfile' }
        ambient: { $ref: '#/components/schemas/AmbientContext' }
    Scan:
      type: object
      properties:
        id: { type: string, format: uuid }
        patient_id: { type: string, format: uuid }
        status: { type: string, enum: [capture_pending, quality_pending, quality_passed, quality_failed, feature_pending, feature_complete, assessment_pending, complete, acquisition_failure, revoked] }
        capture_type: { type: string }
        created_at: { type: string, format: date-time }
        upload_targets: { type: array, items: { $ref: '#/components/schemas/UploadTarget' } }
        max_recaptures_remaining: { type: integer, minimum: 0 }
    Error:
      type: object
      required: [code, message, request_id, timestamp]
      properties:
        code: { type: string }
        message: { type: string }
        detail: { type: object, additionalProperties: true }
        request_id: { type: string }
        trace_id: { type: string }
        timestamp: { type: string, format: date-time }
paths:
  /scans:
    post:
      tags: [scans]
      summary: Initiate a capture session
      operationId: initiateScan
      security: [{ bearerAuth: [] }]
      parameters:
        - in: header
          name: Idempotency-Key
          required: true
          schema: { type: string, format: uuid }
      requestBody:
        required: true
        content: { application/json: { schema: { $ref: '#/components/schemas/ScanInitiateRequest' } } }
      responses:
        '201': { description: Scan created, content: { application/json: { schema: { $ref: '#/components/schemas/Scan' } } } }
        '400': { description: Bad request, content: { application/json: { schema: { $ref: '#/components/schemas/Error' } } } }
        '401': { description: Unauthorized }
        '403': { description: Forbidden }
        '409': { description: Active scan already exists }
        '422': { description: Consent version superseded }
  /scans/{id}:
    get:
      tags: [scans]
      operationId: getScan
      security: [{ bearerAuth: [] }]
      parameters:
        - in: path
          name: id
          required: true
          schema: { type: string, format: uuid }
      responses:
        '200': { description: OK, content: { application/json: { schema: { $ref: '#/components/schemas/Scan' } } } }
        '404': { description: Not found }
```

---

## 2. Authentication & Security

### 2.1 Token Model

The API uses a dual-token JWT model aligned to the Vibe Coding §8.5 Auth Setup Prompt (Clerk/Supabase Auth pattern, protected routes require auth, public routes stay public):

- **Access token** — JWT, RS256-signed, 15-minute TTL. Claims: `sub` (user id), `roles` (array), `site_id`, `cohort_scope`, `deidentify` (bool), `iat`, `exp`, `iss`, `aud`, `jti`. Carried as `Authorization: Bearer <jwt>`.
- **Refresh token** — opaque random 256-bit token, 7-day TTL, single-use with rotation, bound to the device fingerprint and stored hashed in the `auth_refresh_tokens` table. Reuse of a consumed refresh token revokes the entire session family and emits a `security.refresh_reuse` audit event.
- **Service token** — long-lived, mTLS-pinned, role=`system_agent`, used only for machine-to-machine calls (e.g. agentic capture loop → feature extraction → risk engine). Issued via a separate token endpoint behind mTLS and never exposed to a human UI.

### 2.2 Role-Based Access Control (RBAC)

Roles are bound to the governance RACI matrix in DengueSense §11 and to the least-privilege mandate in §8.3.

| Role | Primary职责 | Bound to Site | De-identification | Typical Tasks |
|------|------------|---------------|-------------------|---------------|
| `clinician` | Enrol, capture, run assessments | Yes (own site only) | No (sees direct identifiers for own site) | Patient registration, scan initiation, recapture, clinical-data entry, view assessment |
| `researcher` | Analyse de-identified cohort data | No (cross-site) | Yes | Read patients/scans/features/assessments; subgroup queries |
| `biostatistician` | Train/validate models, hold data lock | No | Yes (training split only) | Feature extraction jobs (read-only on data), dashboard, model-lock sign-off |
| `admin` | Provision users, roles, retention | No | No (operational, no clinical claim) | User CRUD, role changes, soft-delete scans |
| `regulatory_reviewer` | Audit, evidence review, hold/release | No | Yes | Read audit logs, decisions, dashboard summary |
| `system_agent` | Autonomous agentic operations | Yes (per-patient binding) | No (operational) | Run feature extraction, run quality gate, run risk engine, recapture triggers |

### 2.3 Row-Level Security (RLS)

Following the Vibe Coding §2.5 / §8.4 RLS pattern ("Users can only read/write their own rows" extended to multi-tenant clinical data) and the §8.3 least-privilege mandate, RLS is enforced at the database tier using a session variable set per request by the API gateway after JWT verification:

```
-- Per-request session variables (Postgres RLS hooks)
SET LOCAL app.user_id        = 'usr_01HXKE...';
SET LOCAL app.roles          = 'clinician';
SET LOCAL app.site_id        = 'site-ukm-001';
SET LOCAL app.cohort_scope   = '*';
SET LOCAL app.deidentify     = 'false';
SET LOCAL app.trace_id       = 'trc_8b3e...e21c';
```

RLS policies:

| Table | Clinician rule | Researcher rule | Biostatistician rule | Regulatory reviewer rule | Admin rule |
|-------|----------------|------------------|----------------------|---------------------------|------------|
| `patients` | `WHERE site_id = current_setting('app.site_id')` | SELECT only on `patient_pseudonym_id`, `site_bucket`, `cohort`; direct identifiers NULL'd by view | SELECT only where `training_split = TRUE` and `deidentify = TRUE` | SELECT all fields except direct identifiers | SELECT all |
| `scans` | Same site scoping | Same as patient | Same as patient + training split | All | All |
| `features` | Clinical projection (subset of fields) | Full feature set, de-identified | Full feature set on training split only | Snapshot hash + full read | All |
| `assessments` | Own site only | De-identified | Training split | Full read | All |
| `clinical_data` | Own site, full resolution | Cohort bucket rounding | Training split, full resolution | Full read | All |
| `audit_logs` | Own decisions only | None | None | All | All |
| `patient_identifiers` (encrypted) | Denied | Denied | Denied | Denied (only via separate dual-approval linking service) | Denied |

Direct identifiers are stored in a separate `patient_identifiers` table that is **field-level encrypted** (AES-256-GCM, per-row data key wrapped by a KMS master key) and is never returned by the v1 API. The mapping from `patient_id` to `patient_pseudonym_id` is held by a dedicated linking service callable only via a dual-control workflow (admin + regulatory_reviewer approval), and every access is recorded as a `linking.access` audit event.

### 2.4 Permission Matrix (Role × Endpoint)

Cells: ✓ allowed, ✗ denied, ⚠ conditional (e.g. own-site only, training-split only).

| Endpoint | clinician | researcher | biostatistician | admin | regulatory_reviewer | system_agent |
|----------|-----------|------------|------------------|-------|----------------------|--------------|
| POST /auth/login | public | public | public | public | public | mTLS only |
| POST /auth/refresh | ✓ | ✓ | ✓ | ✓ | ✓ | mTLS only |
| POST /auth/logout | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| GET /auth/me | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| POST /patients | ⚠ (own site) | ✗ | ✗ | ✓ | ✗ | ✗ |
| GET /patients/{id} | ⚠ (own site) | ✓ (de-id) | ✓ (de-id, train) | ✓ | ✓ (de-id) | ✗ |
| GET /patients | ⚠ (own site) | ✓ (de-id) | ✓ (de-id, train) | ✓ | ✓ (de-id) | ✗ |
| PATCH /patients/{id} | ⚠ (own site) | ✗ | ✗ | ✓ | ✗ | ✗ |
| POST /scans | ✓ | ✗ | ✗ | ✗ | ✗ | ⚠ (per-patient) |
| GET /scans/{id} | ⚠ (own site) | ✓ (de-id) | ✓ (train) | ✓ | ✓ (de-id) | ⚠ (per-patient) |
| GET /scans | ⚠ (own site) | ✓ | ✓ (train) | ✓ | ✓ | ⚠ (per-patient) |
| DELETE /scans/{id} | ✗ | ✗ | ✗ | ✓ (soft) | ✗ | ✗ |
| POST /scans/{id}/recapture | ✓ | ✗ | ✗ | ✗ | ✗ | ⚠ (per-patient) |
| POST /scans/{id}/features/extract | ✗ | ✗ | ⚠ (read-only jobs) | ✗ | ✗ | ✓ |
| GET /scans/{id}/features | ✓ (clinical proj) | ✓ (de-id) | ✓ (train) | ✓ | ✓ | ✓ |
| POST /assessments | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ |
| GET /assessments/{id} | ⚠ (own site) | ✓ (de-id) | ✓ (train) | ✓ | ✓ | ⚠ (per-patient) |
| GET /patients/{id}/assessments | ⚠ (own site) | ✓ (de-id) | ✓ (train) | ✓ | ✓ | ⚠ (per-patient) |
| POST /scans/{id}/quality-check | ✓ (read) | ✗ | ✗ | ✗ | ✗ | ✓ |
| GET /quality/reason-codes | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| POST /patients/{id}/clinical-data | ✓ | ✗ | ✗ | ✗ | ✗ | ⚠ (per-patient) |
| GET /patients/{id}/clinical-data | ⚠ (own site) | ✓ (bucket) | ✓ (train) | ✓ | ✓ | ⚠ (per-patient) |
| GET /audit/logs | ⚠ (own decisions) | ✗ | ✗ | ✓ | ✓ | ✗ |
| GET /audit/decisions/{id} | ⚠ (own) | ✗ | ✗ | ✓ | ✓ | ✗ |
| GET /dashboard/summary | ✗ | ✓ | ✓ | ✓ | ✓ | ✗ |
| GET /dashboard/subgroups | ✗ | ✓ | ✓ | ✓ | ✓ | ✗ |
| GET /admin/users | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |
| POST /admin/users | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |
| PATCH /admin/users/{id}/roles | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |

### 2.5 Encryption Standards

| Layer | Standard |
|-------|----------|
| Transport | TLS 1.3 with strong ciphers only; HSTS `max-age=63072000; includeSubDomains; preload` |
| At rest (object storage, DB volumes) | AES-256 with envelope encryption; data keys issued by KMS, rotated every 90 days |
| Field-level (direct identifiers) | AES-256-GCM, per-row data key wrapped by KMS master key |
| Backups | Encrypted with separate key ring; copies in two regions |
| Secrets | Vault-stored; rotated per Vibe Coding §4.2 RTO < 4h DR target |

### 2.6 Service-to-Service API Keys

Machine-to-machine traffic (e.g. the agentic capture agent invoking `POST /scans/{id}/features/extract` and `POST /assessments`) does **not** use human JWTs. It uses a service token issued via mTLS to a workload identity (`spiffe://denguesense/system-agent`) and rotated every 24 hours. The token carries an `agent_run_id` so audit records attribute every action to a specific agentic run — closing the traceability gap required by §8.3 "consent, access, export, and deletion logs".

### 2.7 Rate Limiting

| Caller class | Burst | Sustained | Window | On exceed |
|---------------|-------|-----------|--------|-----------|
| `clinician` (UI) | 50 | 100 req/min | sliding 60s | `429` with `Retry-After` |
| `researcher` (read-only) | 100 | 200 req/min | sliding 60s | `429` |
| `biostatistician` (batch) | 200 | 500 req/min | sliding 60s | `429` |
| `admin` | 100 | 200 req/min | sliding 60s | `429` |
| `regulatory_reviewer` | 50 | 100 req/min | sliding 60s | `429` |
| `system_agent` (mTLS) | 1000 | 1000 req/min | sliding 60s | `429` + circuit-breaker back-off |

Rate limits are enforced per `(user_id, route_prefix)` and persisted in a Redis counter; the `429` response includes `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` headers and a `Retry-After` value in seconds.

### 2.8 Authentication Flow Diagram

```
            +--------------------+        +--------------------+
   user -->|  Capture UI / SPA  |------->|  IdP (Clerk /      |
            |  (browser)        | 1. login (email+pw+MFA)   Supabase Auth)     |
            +--------------------+        +--------------------+
                       |                            |
                       | 2. JWT access + refresh     |
                       v                            v
            +--------------------+        +--------------------+
            |  API Gateway       |<------|  Token verification |
            |  /v1/* (RLS set)    |        |  + RLS context build|
            +--------------------+        +--------------------+
                       |
                       | 3. request + bearer JWT
                       v
            +--------------------+        +--------------------+
            |  Postgres + RLS    |        |  Audit log writer  |
            |  (per-request vars)|------->|  (async, append-only)|
            +--------------------+        +--------------------+
                       ^
                       | 4. SQL with WHERE clauses injected by RLS
                       |
            +--------------------+
            |  Service / agentic | mTLS, service token, agent_run_id
            |  workload           |
            +--------------------+
```

---

## 3. Error Handling

### 3.1 Standardised Error Response Format

Every error response is a single JSON envelope conforming to RFC 7807 with two extensions (`trace_id` and `request_id`). The format is identical for transport, domain, and validation errors so that client SDKs and the agentic capture loop can dispatch on `code` deterministically.

```json
{
  "error": {
    "code": "DS_QG_001",
    "message": "Capture failed quality gate: excessive motion.",
    "detail": {
      "check": "motion_head_pose",
      "observed": { "yaw_deg": 18.4, "duration_s": 4.2 },
      "threshold": { "yaw_deg": 15.0, "duration_s": 2.0 },
      "next_action": "recapture"
    },
    "request_id": "req_5c1f8b3e21c",
    "trace_id": "trc_8b3e...e21c",
    "timestamp": "2026-08-12T07:43:55Z",
    "doc_url": "https://docs.denguesense.{tld}/errors/DS_QG_001"
  }
}
```

### 3.2 HTTP Status Code Usage

| HTTP Status | Used for | Example trigger |
|-------------|----------|------------------|
| 400 BadRequest | Malformed payload, schema mismatch | Missing required field |
| 401 Unauthorized | Missing/invalid/expired token | JWT signature mismatch |
| 403 Forbidden | Valid token but RBAC denies action | Clinician accessing another site's patient |
| 404 NotFound | Resource does not exist or is outside RLS envelope | Cross-site GET returning 404 (never 403, to avoid leaking existence) |
| 409 Conflict | Duplicate or state-transition violation | Active scan already exists for patient |
| 422 Unprocessable Entity | Schema valid but business rule fails | Quality gate verdict "fail", insufficient features for risk engine |
| 429 Too Many Requests | Rate limit exceeded | Burst over 100 req/min for clinician |
| 451 Unavailable For Legal Reasons | Regulatory hold active | `DS_REG_001` |
| 500 Internal Server Error | Unhandled exception | Unhandled null dereference |
| 502 Bad Gateway | Upstream IdP or storage unreachable | Clerk down |
| 503 Service Unavailable | Risk engine in maintenance | Pre-announced maintenance window |
| 504 Gateway Timeout | Downstream exceeded SLA | Risk engine > 30 s |

### 3.3 Domain-Specific Error Codes

| Code | HTTP | Meaning | Retry? | User Action |
|------|------|---------|--------|-------------|
| `DS_QG_001` | 422 | Quality gate failure — motion / head-pose drift | No (idempotent recompute returns same verdict) | Recapture with headrest |
| `DS_QG_002` | 422 | Quality gate failure — lighting outside range | No | Reposition participant |
| `DS_QG_003` | 422 | Quality gate failure — occlusion (mask/glasses/hair) | No | Remove occluder if safe |
| `DS_QG_004` | 422 | Quality gate failure — frame-rate / compression artefact | No | Restart capture app |
| `DS_RPPG_001` | 422 | rPPG signal SNR too low for inference | No | Increase capture duration, ensure even lighting |
| `DS_RPPG_002` | 422 | rPPG spectral plausibility below threshold | No | Recapture in quieter lighting |
| `DS_SEG_001` | 422 | Segmentation confidence low (ocular or tongue) | No | Follow recapture instruction in `GET /quality/reason-codes` |
| `DS_RISK_001` | 422 | Insufficient features available for risk inference | No | Capture missing modality or wait for feature job |
| `DS_RISK_002` | 422 | Model card version mismatch with feature set version | No | Re-run extraction with locked feature set version |
| `DS_REG_001` | 451 | Regulatory hold active on patient/site | No | Contact regulatory reviewer |
| `DS_REG_002` | 451 | Consent version superseded; recapture consent required | No | Re-consent patient |
| `DS_AUD_001` | 403 | Audit writer unavailable; mutation refused | Yes (exponential backoff) | Retry later |
| `DS_RLS_001` | 403 | RLS envelope denied access | No | Request access review |
| `DS_IDEMPOTENCY_001` | 409 | Idempotency-Key reused with different payload | No | Use new key |
| `DS_RATE_001` | 429 | Rate limit exceeded | Yes (with `Retry-After`) | Slow down |
| `DS_UPSTREAM_001` | 502 | Upstream IdP unreachable | Yes (circuit-breaker open) | Retry after circuit closes |
| `DS_TIMEOUT_001` | 504 | Downstream exceeded SLA | Yes (only if GET) | Retry with backoff |

### 3.4 Fallback Mechanisms

The system follows §8.3's "do not force a result from inadequate data" rule. The risk engine implements a graceful-degradation ladder:

1. **Primary path** — multimodal (rPPG + facial perfusion + ocular + tongue + clinical).
2. **Degradation A** — if `DS_RPPG_001` and `DS_SEG_001` both fire, drop rPPG and tongue features; rerun risk engine with facial perfusion + ocular + clinical (degraded model card `mc-risk-degraded-A`); flag `degraded=true` on the assessment.
3. **Degradation B** — if any visual modality fails the SQI gate, fall back to the clinical-only baseline model (`mc-risk-clinical-only-baseline`); assessment `risk_band` is emitted with a `low_confidence` flag and a UI banner "Result derived from clinical data only — multimodal signal unavailable".
4. **Acquisition failure** — after the approved maximum recaptures, the scan transitions to `acquisition_failure`. No assessment is produced; a `DS_QG_099` audit decision is written and the clinician is offered a manual rebooking flow.

The agentic capture loop (Doc 02) is the canonical caller of the degradation ladder and treats `degraded=true` as a non-blocking outcome — it informs the clinician and continues the session.

### 3.5 Circuit Breaker Pattern

Downstream dependencies (IdP, object storage, KMS, risk engine) sit behind a circuit breaker:

- **Closed** — normal operation.
- **Open** — after 5 consecutive failures or 30 s of > 50% error rate, the breaker opens for 30 s; calls return `503` with `Retry-After: 30`.
- **Half-open** — 10% of traffic is allowed through; if it succeeds, the breaker closes.

The risk engine has its own breaker with a 60 s open window, because risk inference can legitimately take 10–30 s.

### 3.6 Retry Logic

- **Idempotent operations** (`GET`, `POST /scans`, `POST /assessments`, `POST /scans/{id}/quality-check` with same `Idempotency-Key`) — clients retry with exponential backoff: `delay = min(base * 2^n + jitter, cap)` where base = 200 ms, cap = 5 s, max 3 retries.
- **Non-idempotent clinical writes** (`POST /patients/{id}/clinical-data` with a fresh observation timestamp) — clients must NOT retry automatically; the SDK surfaces the error to the clinician UI for explicit re-submit.
- **Non-idempotent mutations** (`PATCH`, `DELETE`) — clients may retry only on `5xx` and only after a successful `GET` confirms the prior attempt did not mutate state.
- All retries carry the original `Idempotency-Key` and `trace_id` so the server can collapse duplicates.

### 3.7 Idempotency Keys

Every `POST` accepts an `Idempotency-Key: <uuid v4>` header. The server stores a 24-hour fingerprint of `(user_id, method, route, key, payload_hash)`. A replay with the same key and same payload returns the original response (including the original `201 Created` status). A replay with the same key but a different payload returns `409` with code `DS_IDEMPOTENCY_001`. A replay after key expiry is treated as a fresh request.

### 3.8 Error Handling Flow Diagram

```
   Request
      |
      v
   [JWT + RLS verify]  -- fail --> 401 / 403 (no DB write)
      |
      v
   [Schema validate]  -- fail --> 400
      |
      v
   [Idempotency-Key check]  -- duplicate+diff payload --> 409 DS_IDEMPOTENCY_001
      |                                                -- duplicate+same payload --> return cached response
      v
   [RBAC check]  -- fail --> 404 (never 403, to hide existence)
      |
      v
   [Business rule]  -- quality gate fail --> 422 DS_QG_*
      |             -- insufficient features --> 422 DS_RISK_001
      |             -- regulatory hold --> 451 DS_REG_001
      v
   [Downstream call] -- breaker open --> 503 DS_UPSTREAM_001
      |              -- timeout --> 504 DS_TIMEOUT_001
      v
   [Audit writer]  -- fail --> 403 DS_AUD_001 (mutation refused; no silent success)
      |
      v
   2xx + audit decision id
```

### 3.9 Logging, Tracing, Observability

Every request gets a `request_id` (UUID, returned in the `X-Request-Id` header) and joins a `trace_id` (propagated via the W3C `traceparent` header) that is also written into the audit log. The agentic capture loop passes its own `agent_run_id` so a full clinical capture → assess → fallback chain can be reconstructed end-to-end for regulatory review (DengueSense §8.3 audit mandate).

### 3.10 Versioning & Deprecation

The API is versioned at the URL (`/v1`, `/v2`). Breaking changes require a new major version with a 12-month overlap window. Deprecations are announced via the `Deprecation` and `Sunset` response headers per RFC 8594. Non-breaking additions (new optional fields, new endpoints) do not require a version bump.

---

## 4. Cross-Cutting Implementation Notes

1. **RLS is the last line of defence, not the first.** The API gateway must reject cross-site requests before they reach Postgres. RLS exists to guarantee that even a bug in the gateway cannot leak cross-site data — directly satisfying the §8.3 least-privilege and pseudonymisation mandates.
2. **Direct identifiers never appear in v1 JSON.** Any feature, scan, assessment, or clinical-data response that would normally include `mrn`, `nric`, or `name` instead returns `patient_pseudonym_id`. The linking service is a separate, dual-approval endpoint outside v1.
3. **Audit writer is on the synchronous critical path.** If the audit writer is unavailable, mutations return `403 DS_AUD_001` rather than silently succeeding — preserving §8.3's "access, export, and deletion logs maintained throughout the programme lifecycle" guarantee.
4. **System-agent tokens carry `agent_run_id`.** Every agentic action is traceable to a specific run, supporting the §11 governance accountability principle.
5. **All timestamps include `feature_availability_timestamp`.** This implements the anti-leakage rule from DengueSense §6 — pre-outcome models must never see post-outcome variables.
6. **Quality gate is the only path to feature extraction.** `POST /scans/{id}/features/extract` returns `422` if the scan is not in `quality_passed` state — operationalising §8.3's "inference blocked when any critical quality rule fails" mandate.

---

## 5. Compliance Cross-Reference

| §8.3 Requirement | Implementation in this API |
|-------------------|----------------------------|
| Only protocol-required data collected | Endpoint schemas reject unspecified fields (400) |
| Direct identifiers separated from research data | `patient_identifiers` table, field-level encrypted, never in v1 JSON |
| Encrypted in transit and at rest | TLS 1.3 + AES-256 envelope + field-level AES-256-GCM |
| Role-based access with least privilege | §2.4 permission matrix + §2.3 RLS policies |
| Periodic access review | `last_access_review_at` field on user; `PATCH /admin/users/{id}/roles` triggers notification |
| Consent, access, export, deletion logs | `/audit/logs` and `/audit/decisions/{id}` immutable endpoints |
| Retention / archival / destruction rules | Soft-delete + dual-approval retention purge, retention window enforced server-side |
| Cross-border transfer rules | Response includes `data_residency_region` for downstream enforcement |
| No secondary use | Feature extraction `extractor_pipeline` list bounds what each model can see |
| No identity recognition | Facial payloads are never used for face recognition; segmentation masks are discarded after feature extraction |
| Threat modelling, pen testing, incident response | Pre-multi-site gate; this API surfaces `DS_AUD_001` / `DS_REG_001` to support rehearsed incident plans |
| PDPA 2010 + 2024 amendment | Right to access via `/audit/logs`; right to erasure via dual-approval retention purge |

---

## 6. Change Log

| Version | Date | Author | Notes |
|---------|------|--------|-------|
| 0.1 | 2026-08-12 | API Reference task agent | Initial draft covering 29 endpoints, RBAC, RLS, error catalog, OpenAPI snippet |
