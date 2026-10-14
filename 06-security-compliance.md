# Security, Compliance, & Risk Mitigation

**Document:** 06 — Security, Compliance, and Risk Mitigation
**Programme:** beAIve DengueSense — Multimodal AI-Driven Dengue Risk Assessment
**Prepared for:** reAInmaker SDN BHD (Kuala Lumpur, Malaysia)
**Audience:** Security Architect, Compliance Officer, DPO, Privacy & Security Review Body, MDA/NMRR reviewers
**Version:** 1.0 (planning baseline)
**Status:** Maps to DengueSense §8.3 Privacy & Security Baseline, §10 Risk Register (R1–R15), and Vibe Coding §15.2 Security Deployment Checklist

---

## 1. Data Privacy: Compliance Framework for Sensitive Health Data

DengueSense processes biometric facial video, ocular and tongue imagery, rPPG-derived physiological signals, and clinical metadata that, in combination, can re-identify an individual and reveal health status. This section defines the layered privacy framework that governs every byte from capture to destruction, grounded in three legal/policy anchors — the **Personal Data Protection Act 2010 (PDPA)** and the **Personal Data Protection (Amendment) Act 2024**, the **NIH Malaysia Data Access and Use Policy**, and the programme's own §8.3 Privacy and Security Baseline — operationalised through ISO/IEC 27001 controls and IEC 81001-5-1 security-by-design clauses applicable to medical-device software.

### 1.1 Regulatory Anchors

#### 1.1.1 Malaysia PDPA 2010 and 2024 Amendment

The PDPA 2010 governs processing of personal data in commercial transactions via seven binding principles: General, Notice and Choice, Disclosure, Security, Retention, Data Integrity, and Access. Health data is *sensitive personal data* (Section 2), requiring explicit consent (Section 7) before processing unless an exemption applies. The **2024 Amendment** introduces materially stricter obligations that the Privacy and Security Review Body must address before G3 (ethics & site-initiation):

- Mandatory **Data Protection Officer (DPO)** appointment and JPDP registration.
- Mandatory **data breach notification** within a prescribed window (operationally "without undue delay and within 72 hours of awareness" pending gazetted regulations).
- **Data portability** rights, requiring structured, machine-readable export.
- Recognition of **data processors** as separately accountable — reAInmaker, as controller, must flow contractual security obligations to every processor (cloud host, OCR vendor, training-compute provider).
- Strengthened **cross-border transfer** rules: data may leave Malaysia only to JPDP-whitelisted jurisdictions or under approved BCRs / SCCs.

A formal DPIA is completed before G3 and refreshed at each stage gate, reviewed by the Privacy and Security Review Body (monthly during build, quarterly thereafter per §11).

#### 1.1.2 NIH Malaysia Data-Access Policy and NMRR/MREC

Because the programme uses MoH resources, sites, and clinicians, the NIH Malaysia data-access policy applies. Qualifying human-subject research requires **NMRR registration** of the protocol before any recruitment; **MREC ethics approval** with full consent forms, information sheets, and data-management plan attached; **site-specific approvals** from each participating hospital's director and ethics committee; **data-processing agreements (DPAs)** between reAInmaker, the sponsor institution, and each site, executed before the first participant is enrolled; and **investigator commitments** in writing that scope, retention, and destruction obligations are understood.

For future commercial deployment, the programme must additionally confirm **MDA establishment licensing**, **conformity assessment** under the Medical Device Act 2012, and post-market obligations — these are tracked in the Regulatory workstream but inform retention and deletion timelines here.

#### 1.1.3 DengueSense §8.3 Privacy and Security Baseline

The programme's own baseline mandates data minimisation, pseudonymisation, encryption in transit and at rest, role-based least-privilege access with periodic review, consent/access/export/deletion logs throughout the lifecycle, retention/archival/destruction/cross-border rules defined before recruitment, strict prohibition on secondary use / identity recognition / model reuse outside approved consent, and complete threat modelling, penetration testing, and incident-response exercises before multi-site deployment. Each clause is converted into an actionable control in §1.8 (compliance checklist) and a testable verification in the §4.4 security checklist.

### 1.2 Data Minimisation

Every data element captured by the Capture & Guidance module is enumerated in the Data Dictionary (Document 03) and mapped to a protocol purpose. No "nice-to-have" fields are collected. Specific minimisation controls include:

- The capture interface surfaces **only the Study ID** — no name, NRIC, or hospital MRN on screen during recording.
- Raw video is **trimmed to the protocol window** (30–45 s facial, 10 s ocular, 10–15 s dorsal tongue); no pre-roll or post-roll retained.
- Audio is **never captured**; microphones physically muted at the device level.
- GPS, IP address, and device identifiers are **hashed at the edge** before cloud upload; the salt is held by the site custodian, not by reAInmaker.
- Clinical inputs are limited to the SAP-approved predictor list — fields outside the model specification are rejected at the API schema layer.

A Data Element Inventory (DEI) is maintained and version-controlled; any addition requires Privacy and Security Review Body approval.

### 1.3 Pseudonymisation Architecture

Direct identifiers (name, NRIC, contact details, hospital MRN, date of birth, address) are **separated from research data at the point of capture** and held in a Token Vault that is logically and physically distinct from the Research Data Store. The linkage key is generated by the site's trusted custodian using a keyed HMAC-SHA-256 with a site-held secret; reAInmaker engineering never sees the key.

```json
{
  "consent_record": {
    "record_id": "CR-2026-0000142",
    "study_id": "DS-UKM-00417",
    "participant_pseudonym": "0a4f...e2c9",
    "site_code": "UKM-PP",
    "consent_version": "v3.2-2026-07",
    "language": "ms-MY",
    "consenting_clinician_id": "USR-CL-0089",
    "witness_id": "USR-WT-0011",
    "captured_at": "2026-08-14T03:17:42Z",
    "scope": {
      "primary_research": true,
      "secondary_use": false,
      "identity_recognition": false,
      "model_reuse_outside_programme": false,
      "international_transfer": false
    },
    "retention_class": "RM-CLIN-7Y",
    "withdrawal_window": "until_data_lock_2028-12-31",
    "signature": "3046...b1f7",
    "signature_alg": "ECDSA-P256-SHA256"
  }
}
```

### 1.4 Encryption

Encryption is enforced in three layers:

- **In transit:** TLS 1.3 mandatory for every network hop (capture device → API gateway → microservice → database → object store). TLS 1.2 deprecated. mTLS between internal services via a private CA (see §2.1). Cipher suites restricted to `TLS_AES_256_GCM_SHA384` and `TLS_CHACHA20_POLY1305_SHA256`; key exchange limited to ECDHE with P-384.
- **At rest:** AES-256-GCM for the Research Data Store, Token Vault, audit log, object storage, and database volumes. Keys are managed in a FIPS 140-3 Level 3 HSM (cloud KMS or on-prem Thales/Gemalto) with rotation every 90 days and split-knowledge (dual control) for key wrapping.
- **Field-level:** Direct identifiers receive **additional field-level encryption** with a per-record data-encryption key (DEK) wrapped by a master key (KEK) — so even an authenticated DB user cannot decrypt identifiers without the unwrapping service. Biomarker-derived feature vectors are hashed with salted SHA-256 for cross-cohort deduplication.

### 1.5 Retention, Archival, Destruction, and Cross-Border Transfer

All four lifecycle events are defined **before recruitment** (per §8.3) and recorded in the Data Management Plan:

- **Retention:** Research data retained for **7 years** from data lock (aligned to medical-device record requirements under MDA and ISO 13485 §4.2.5). Consent and audit logs retained for the same period.
- **Archival:** At study close, data is moved to cold storage (e.g., S3 Glacier Deep Archive) with byte-level checksums and quarterly integrity audits. Archive keys are held by the Privacy Officer and DPO under M-of-N control.
- **Destruction:** Cryptographic erasure for active storage (overwrite keys with random data → AES-256 plaintext unrecoverable) plus physical destruction of decommissioned media (NIST SP 800-88 Purge/Destroy). A destruction certificate is issued per participant batch.
- **Cross-border transfer:** Default posture is **in-country processing** (Malaysian region of a hyperscaler, or on-prem at UKM). Any transfer outside Malaysia requires: (a) JPDP whitelist confirmation, (b) Privacy and Security Review Body approval, (c) updated consent capture, (d) Standard Contractual Clauses or Binding Corporate Rules.

### 1.6 Consent Management

Consent is granular, revocable, and version-controlled. Each participant's consent record (JSON in §1.3) records form version, language, consenting clinician, witness, and explicit toggles for primary research, secondary use, identity recognition, model reuse, and international transfer. The §8.3 prohibition on **identity recognition outside approved consent** is enforced technically: the Facial Recognition Service is a separate opt-in module **off by default**; the Capture module's identity check uses **study ID only** (no face-recognition call in the default workflow); and the Risk Engine operates on **pseudonymised features**, never on raw facial embeddings that could be reversed to identity. Withdrawal is honoured until data lock; after data lock, anonymised contributions may be retained if the consent version permits, otherwise cryptographic erasure is applied.

### 1.7 Subject Rights

Participants retain the right to access, export, correct, and request deletion of their data throughout the programme lifecycle, subject to protocol and regulatory constraints. Subject-access requests (SARs) are fulfilled within 30 days via the DPO and logged in the audit trail. Export is provided as JSON + DICOM for imagery per PDPA 2024 portability provisions.

### 1.8 Compliance Checklist

| # | Requirement | Standard / Law | Implementation | Verification |
|---|---|---|---|---|
| 1 | Lawful basis & explicit consent for sensitive data | PDPA 2010 s.6, s.7; 2024 Amendment | Granular consent record (JSON §1.3) with versioned form | MREC approval letter; consent DB row audit |
| 2 | Data minimisation | §8.3 Baseline; ISO/IEC 27001 A.8.2 | Data Element Inventory; schema-level rejection of out-of-scope fields | Quarterly DEI review by Privacy Officer |
| 3 | Pseudonymisation / separation of identifiers | §8.3 Baseline; GDPR Art.32 (best practice) | Token Vault with site-held HMAC key | Architecture review at G3; pentest confirms no identifier leakage |
| 4 | Encryption in transit | ISO/IEC 27001 A.8.4; IEC 81001-5-1 | TLS 1.3 + mTLS, restricted ciphers | SSL Labs A+; mTLS cert inventory |
| 5 | Encryption at rest | ISO/IEC 27001 A.8.4 | AES-256-GCM, KMS in FIPS 140-3 L3 HSM | KMS audit log; quarterly key rotation evidence |
| 6 | Field-level encryption for identifiers | §8.3 Baseline | Per-record DEK wrapped by KEK | DB pentest (privilege-escalation test) |
| 7 | Access control & least privilege | §8.3 Baseline; ISO/IEC 27001 A.9 | RBAC + ABAC; periodic review | Quarterly access review; quarterly JIT grants report |
| 8 | Audit logging of consent, access, export, deletion | §8.3 Baseline; ISO/IEC 27001 A.12.4 | Immutable append-only log (see §3) | Daily integrity check; annual external audit |
| 9 | Retention rules defined pre-recruitment | PDPA 2010 s.10; §8.3 Baseline | DMP v1.0 signed at G3 | Retention register; G3 gate evidence |
| 10 | Archival & destruction procedures | ISO 13485 §4.2.5; NIST SP 800-88 | Cryptographic erasure + physical destruction | Destruction certificates |
| 11 | Cross-border transfer controls | PDPA 2024 Amendment | Whitelist check + SCCs + consent re-capture | DPO sign-off per transfer |
| 12 | Breach notification | PDPA 2024 Amendment | 72-hour notification runbook | Annual tabletop exercise |
| 13 | DPO appointment & registration | PDPA 2024 Amendment | DPO on-boarded; JPDP registration | Registration certificate |
| 14 | Prohibition on secondary use / identity recognition | §8.3 Baseline | Feature flags off-by-default; consent-gated modules | Code review; release engineering sign-off |
| 15 | Threat modelling & pentest pre multi-site | §8.3 Baseline; ISO 14971 | STRIDE (§2) + annual pentest | Pentest report at G3; annual re-test |
| 16 | NMRR registration & MREC approval | NIH Policy; MDA Act 2012 | NMRR ID issued; MREC approval letter | G3 gate evidence |
| 17 | DPIA before processing | PDPA 2024 (best practice) | DPIA v1.0 at G2; refreshed each gate | Privacy Officer sign-off |
| 18 | Subject rights (access, export, deletion) | PDPA 2010 s.7; 2024 portability | SAR workflow; JSON+DICOM export | SAR log; quarterly SAR report |

---

## 2. Threat Modeling: Vulnerabilities & Mitigations

Threat modelling follows the **STRIDE** methodology (Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege) and is performed iteratively: a full session at G2 (architecture freeze), refresh at G3 (pre-deployment), refresh at G5 (model lock), and after every major change. Each STRIDE category is mapped to DengueSense-specific attack surfaces — capture device, API gateway, feature pipeline, model registry, agentic orchestration layer, dashboard, and audit subsystem.

### 2.1 Spoofing

**Threat surface:** Capture device impersonation, fake API submissions, credential replay, service-to-service identity forgery.

**Mitigations:**
- **Device attestation + JWT + mTLS:** capture devices register a hardware-backed attestation token (TPM/Secure Enclave) renewed every 24 hours; every internal RPC requires both a valid OAuth2 JWT (audience-scoped, 5-minute lifetime, `jti` replay-cached in Redis) and an mTLS client certificate from the private service CA. Service mesh (Istio/Linkerd) automates this.
- **Replay protection:** nonce-protected uploads for capture sessions; JWT includes a `jti` claim cached in Redis for the token lifetime.
- **User MFA:** clinicians authenticate with SSO + WebAuthn (passkeys) — password-only login is disabled (see §4.4).

### 2.2 Tampering

**Threat surface:** Training data poisoning (R3 manifestation), model artefact tampering, in-transit data modification, agentic prompt injection.

**Mitigations:**
- **Training data provenance:** every frame is tagged with capture session, device attestation hash, site code, and submitter identity; provenance graph (e.g., OpenLineage) is queried before training runs.
- **Input validation:** schema, range, and statistical checks at ingest (pixel histogram anomaly detection, rPPG signal-plausibility checks).
- **Signed model artefacts:** models stored in a registry (MLflow + Sigstore/cosign); inference servers refuse to load any artefact whose signature does not match the registry root of trust.
- **Adversarial robustness tests:** as part of G5 model lock, a red team submits perturbed frames; threshold degradation must remain within prespecified bounds.
- **Prompt sanitisation (agentic LLM only):** system prompt isolated from user input via delimiter-based context separation; outputs validated against a clinical-text JSON schema; tool calls restricted to an allowlist; dangerous actions require human-in-the-loop confirmation.

### 2.3 Repudiation

**Threat surface:** Clinician denies acknowledging or overriding a risk score; site denies submitting a batch; engineer denies deploying a model version.

**Mitigations:**
- Every clinician action (view, acknowledge, override, dismiss) writes an immutable audit entry signed with the clinician's WebAuthn-bound private key (see §3).
- Model deployment is gated by four-eyes approval; deployment events are signed by both the release engineer and the approving security officer.
- Receipts: every data submission returns a signed receipt hash; non-repudiation is provable by recomputing the entry's `prev_hash` chain.

### 2.4 Information Disclosure

**Threat surface:** PHI leakage in logs, model memorisation of training data, misconfigured storage buckets, over-broad error messages.

**Mitigations:**
- **Differential privacy in training:** DP-SGD with ε ≤ 8 for the rPPG and ocular models; privacy budget tracked across releases.
- **Output filtering:** model outputs are risk band + probability + uncertainty; raw embeddings are never returned to the dashboard.
- **Storage hardening:** all buckets private by default; bucket policies deny `aws:SecureTransport=false`; S3 Block Public Access enabled.
- **Log redaction & error handling:** structured logger with PII scrubber (regex + entropy-based token detection) before any log is written to the ops stream; generic user-facing error messages, full stack traces only in the secure error store.

### 2.5 Denial of Service

**Threat surface:** Capture flood, inference overload, audit-log write saturation, agentic reflection loop.

**Mitigations:**
- **Rate limiting:** Nginx `limit_req` of 10 r/min per JWT for inference endpoints, 60 r/min for dashboard; per-device cap of 5 captures per hour; per-site daily quota tracked in Redis.
- **Queue-based processing:** capture submissions go to an SQS/Kafka topic with bounded depth; workers pull at a controlled rate; overflow returns HTTP 429 with `Retry-After`.
- **Circuit breakers:** each model service wraps inference in a circuit breaker (Resilience4j); 5 consecutive failures open the circuit for 60 s and fall back to a calibrated baseline risk band.
- **Agentic step budget:** the Risk Engine agent is bounded to N=10 reasoning steps and T=30 s wall-clock; exceeding the budget triggers a deterministic fallback path.

### 2.6 Elevation of Privilege

**Threat surface:** RBAC bypass, agentic agent privilege escalation, container escape, key theft.

**Mitigations:**
- **Least-privilege service accounts:** each microservice has its own IAM role scoped to the exact resources it needs (inference service: read model objects, write audit log, nothing else).
- **Agent action allowlists:** the agentic Risk Engine's tools are restricted to read-current-patient-features, run-inference, write-audit, request-clinician-review; any other tool call is rejected at the policy layer (OPA Rego).
- **Human-in-the-loop for clinical actions:** the agent cannot write a clinical note, order a lab test, or escalate to ICU without a clinician's WebAuthn-signed approval.
- **Container & key isolation:** read-only root FS, dropped capabilities, seccomp, non-root user, Pod Security Admission `restricted`; the agent has no access to the KMS unwrap API (identifier decryption happens in a separate trusted service).

### 2.7 Deep-Dive: API Injection

Although the schema is JSON-first, the reporting layer issues SQL against the analytics warehouse, and the Capture service uses object storage with templated keys:

- **SQL injection:** every query is parameterised via the ORM's prepared-statement layer (SQLAlchemy `bindparam`, Prisma `$queryRaw`); concatenation of user input into SQL is forbidden and blocked by lint rule in CI.
- **NoSQL injection:** queries accept only typed objects; `$where`, `$function`, and untrusted field-name injection are blocked by schema validators.
- **Command injection:** no `exec()` / `os.system()`; shell calls use `subprocess.run(..., shell=False)` with explicit argument lists.
- **WAF:** Cloudflare/AWS WAF with OWASP CRS rule set, plus custom rules for the study-ID format and capture endpoint.

### 2.8 Deep-Dive: Model Poisoning

Model poisoning defence is a first-class concern because the model is the medical device. Beyond §2.2:

- **Provenance tracking:** every training sample is tagged with `submission_id`, `device_attestation_hash`, `site_code`, `submitted_by`, `qc_pass`; lineage is preserved and reproducible.
- **Statistical anomaly detection:** per-feature distributions monitored at ingest; outliers flagged for human review before inclusion in a training set.
- **Site-held-out validation:** at G5, the model is evaluated on a held-out site that contributed no training data; performance drop beyond the SAP threshold triggers forensic review for site-specific artefacts (directly mitigates **R3**).
- **Adversarial test suite + spectral weight analysis:** red-team suite run at every model lock; post-training weight spectra compared against prior release, large deviations triggering investigation.

### 2.9 Deep-Dive: Prompt Injection (Agentic LLM Components)

If the Risk Engine or the Research Dashboard's explanation feature uses an LLM in an agentic loop:

- **System prompt isolation:** the system prompt is in a separate message role, never concatenated with user-controlled input; delimiters (`<<<USER_INPUT>>>`) are used and the model is instructed to never treat content inside delimiters as instructions.
- **Output validation:** LLM outputs are parsed against a strict JSON schema (risk band, probability, uncertainty, reasoning citations); invalid outputs are rejected and the agent falls back to the deterministic path.
- **Action allowlisting:** the LLM cannot directly invoke any tool outside the allowlist; tool calls are mediated by the policy engine.
- **Indirect prompt injection defences:** any external text the LLM reads (e.g., clinical notes) is sandboxed and explicitly marked as untrusted data, not instructions. Token consumption per request is capped; anomalies trigger investigation.

### 2.10 Threat Model Summary

| # | Threat | STRIDE | Likelihood | Impact | Mitigation | Residual Risk |
|---|---|---|---|---|---|---|
| T1 | Fake capture client submits synthetic data | Spoofing | Medium | High | Device attestation + JWT + mTLS | Low |
| T2 | Adversarial training-data injection | Tampering | Medium | Critical | Provenance, anomaly detection, signed artefacts, site-held-out validation | Medium |
| T3 | In-transit data modification | Tampering | Low | High | TLS 1.3, mTLS, MAC verification | Very Low |
| T4 | Clinician denies override action | Repudiation | Medium | Medium | Immutable signed audit log (§3) | Very Low |
| T5 | PHI leakage via logs or error messages | Info Disclosure | Medium | Critical | Log redaction, DP-SGD, output filtering, generic errors | Low |
| T6 | Model memorises rare participant | Info Disclosure | Low | Critical | Differential privacy (ε ≤ 8), output filtering | Medium |
| T7 | Misconfigured bucket exposes videos | Info Disclosure | Low | Critical | Private-by-default, BPA, Boto3 lint rule in CI | Very Low |
| T8 | Capture flood / inference overload | DoS | High | Medium | Rate limiting, queues, circuit breakers, agent step budget | Low |
| T9 | RBAC bypass via API bug | Elevation | Low | Critical | OPA Rego policy, automated authz tests in CI, quarterly review | Low |
| T10 | Agentic agent escalates privileges | Elevation | Low | Critical | Allowlisted tools, HITL for clinical actions, separate KMS service | Low |
| T11 | Prompt injection of LLM (if used) | Tampering | Medium | High | System-prompt isolation, schema validation, allowlist | Medium |
| T12 | SQL/NoSQL/command injection | Tampering | Low | High | Parameterised queries, no shell exec, WAF, lint rules | Very Low |
| T13 | Credential theft from container | Elevation | Low | Critical | Non-root, read-only FS, scoped IAM, secrets in KMS | Low |
| T14 | Replayed JWT after session expiry | Spoofing | Medium | Medium | Short TTL, jti cache, refresh-token rotation | Very Low |
| T15 | Insider exfiltration of identifiers | Info Disclosure | Medium | Critical | Token Vault separation, field-level encryption, DLP, quarterly access review | Medium |

### 2.11 Penetration Testing Cadence

- **Pre-deployment (G3):** full external + internal pentest by an independent CREST-registered firm with STRIDE-driven test cases; report must show **zero Critical/High** open to pass G3.
- **Annual:** full re-test regardless of change volume.
- **After major changes:** any change to the auth subsystem, RBAC policy, model registry, or agentic Risk Engine triggers a scoped re-test within 30 days.
- **Continuous:** automated DAST (OWASP ZAP) nightly against staging; SAST (Semgrep) and SCA (Snyk/OSV) on every PR; secret scanning (gitleaks) pre-commit.

---

## 3. Audit Logging: Immutable Standards for Agent & System Actions

The audit log is the legal backbone of the programme — without it, the §8.3 requirement to maintain "consent, access, export, and deletion logs throughout the programme lifecycle" is unverifiable, and ISO 13485 §4.2.5 record-control requirements are unmet. The DengueSense audit log is designed as an **append-only, hash-chained, digitally signed** stream, isolated from operational logs, with a minimum 7-year retention and legal-hold capability.

### 3.1 Architecture

Audit events are emitted by every service that touches participant data or makes a decision on its behalf. Events flow through a dedicated pipeline logically separate from the application/operations log stream — operational logs may be rotated, sampled, or shipped to a vendor for debugging; audit logs may not. The pipeline is depicted below.

```
                 +---------------------------+
                 |   Emitting Services       |
                 |  (Capture, Risk Engine,   |
                 |   Dashboard, Auth, Agent) |
                 +-------------+-------------+
                               |
                          audit event (JSON, signed locally)
                               |
                               v
                 +-------------+-------------+
                 |  Audit Ingest Bus         |
                 |  (Kafka, partitioned,     |
                 |   TLS, mTLS, SASL)        |
                 +-------------+-------------+
                               |
              +----------------+----------------+
              |                                 |
              v                                 v
 +------------+-------------+       +------------+-------------+
 | Audit Validator         |       | Schema Registry          |
 | (signature verify,     |       | (JSON Schema, versioned) |
 |  schema check, dedup)   |       +--------------------------+
 +------------+-------------+
              |
              v
 +------------+-------------+
 | WORM / Append-Only      |
 | Hash-Chained Store      |
 | (prev_hash -> curr)     |
 | (S3 Object Lock + Cosign|
 |  signed batch manifest) |
 +------------+-------------+
              |
              v
 +------------+-------------+
 | Merkle Root Publisher    |
 | (hourly root, published  |
 |  to notice board +      |
 |  notarised on a          |
 |  transparency log)      |
 +------------+-------------+
              |
              v
 +------------+-------------+
 | Compliance Query API    |
 | (read-only, scoped to   |
 |  Compliance Officer +   |
 |  Regulator roles only)  |
 +--------------------------+
```

### 3.2 What Gets Logged

Every event in one of these five categories must produce an audit entry:

1. **Model decisions:** input hash (not the input itself, to limit PHI), output, confidence/uncertainty, model version, latency, fallback triggered (Y/N).
2. **Clinician actions:** view result, acknowledge, override (with reason), dismiss, request re-capture, export.
3. **Data access:** read of any PHI field, list-query by patient, export of a patient record, deletion (soft and hard), batch export.
4. **Agentic agent actions:** plan step, tool call (with arguments and result), reflect step, correction step, escalation-to-human.
5. **Auth & admin events:** login, MFA challenge, JWT issuance, role assumption, RBAC policy change, key rotation, deployment, model-lock event, configuration change.

### 3.3 Audit Log Entry Schema

```json
{
  "event_id": "evt-01HNQ7K3X8Y2J4M6P9R0T5V8W",
  "timestamp": "2026-08-14T03:18:09.421Z",
  "actor_id": "USR-CL-0089",
  "actor_type": "human",
  "actor_role": "clinician",
  "action": "risk_acknowledge",
  "resource": {
    "type": "risk_score",
    "study_id": "DS-UKM-00417",
    "version": "v2-2026-08-14T03:17:55Z"
  },
  "outcome": "success",
  "request_hash": "sha256:9b1d...e4a2",
  "input_hash": "sha256:7c3f...11b8",
  "model_version": "rPPG-Ocular-RiskEngine-2026.07",
  "confidence": 0.83,
  "uncertainty": 0.07,
  "prev_hash": "sha256:1f0a...c9d2",
  "merkle_seq": 4129037,
  "signature": "MEUCIQDx...Q8k=",
  "signature_alg": "ECDSA-P256-SHA256",
  "signer": "audit-svc@dainmaker.internal",
  "client_ip": "10.42.7.18",
  "user_agent_hash": "sha256:a1b2...f0e1",
  "session_id": "sess-01HNQ7J1...",
  "consent_ref": "CR-2026-0000142"
}
```

### 3.4 Audit Log Field Reference (Core Fields)

| Field | Type | Required | Description |
|---|---|---|---|
| `event_id` | ULID | Yes | Globally unique, time-sortable identifier |
| `timestamp` | RFC 3339 UTC | Yes | Event time at the emitting service |
| `actor_id` / `actor_type` / `actor_role` | string / enum / string | Yes | Pseudonymous actor ID; `human` \| `agent` \| `system`; role at time of action (clinician, researcher, compliance officer, agent-risk-engine, audit-svc) |
| `action` / `outcome` | enum / enum | Yes | Verb describing what was done; `success` \| `failure` \| `denied` \| `fallback` |
| `resource.type` / `resource.study_id` / `resource.version` | string / conditional / conditional | Yes | Resource kind (risk_score, capture_session, audit_log, model_artefact) and affected participant/version |
| `request_hash` / `input_hash` | string / conditional | Yes | SHA-256 of canonicalised request body; hash of model input (model decision events) |
| `model_version` / `confidence` / `uncertainty` | conditional | Conditional | Model artefact version and probability/uncertainty (model decision events) |
| `prev_hash` / `merkle_seq` | string / integer | Yes | SHA-256 of previous entry; sequence within current Merkle batch |
| `signature` / `signature_alg` / `signer` | string / string / string | Yes | ECDSA-P256 signature over the canonicalised entry (excluding `signature`); algorithm; identity of signing service (`audit-svc`) |
| `client_ip` / `user_agent_hash` / `session_id` / `consent_ref` | optional / optional / yes / conditional | Mixed | Source IP (redacted after retention); hashed user agent for forensics; session correlation ID; consent record reference when participant data is involved |

### 3.5 Integrity Mechanisms

- **Hash chaining:** each entry includes `prev_hash`, the SHA-256 of the previous entry's canonicalised representation. Tampering with any historical entry invalidates the chain from that point onward.
- **Merkle tree roots:** hourly, the audit service computes a Merkle root over the entries since the last publication and posts it to: (a) an internal notice board, (b) a write-once transparency log (e.g., Trillian-style append-only log), and (c) a notarised email to the Compliance Officer — making retroactive tampering externally detectable.
- **Object Lock:** the underlying object storage (S3 Object Lock in Compliance mode) prevents deletion even by root users for the retention window.
- **Signatures:** every entry is signed by `audit-svc` using an ECDSA-P256 key held in the HSM; key rotation every 12 months with the prior public key retained for verification.
- **Dual control:** any modification to the audit service itself (code, config, key rotation) requires four-eyes approval and is itself an audit-logged event.

### 3.6 Access to Audit Logs

Audit logs are **separate from operational logs** — ops logs (DEBUG/INFO for engineering) live in the standard observability stack; audit logs live in a dedicated account with strict access policy. Read access is granted only to the Compliance Officer, the DPO, the Privacy and Security Review Body (read-only, time-bounded grants), and external regulators on lawful request. All reads of the audit log are themselves audit-logged (meta-audit), preventing invisible snooping. A Compliance Query API supports filtered queries (by participant, actor, action, time range) with pagination and rate limiting; raw downloads are prohibited — only anonymised, aggregated exports leave the platform, and only after DPO sign-off.

### 3.7 Retention and Legal Hold

- **Minimum retention:** 7 years from data lock (aligned with medical-device record requirements under MDA and ISO 13485 §4.2.5); the audit log retention equals the longest retention class of any data it references.
- **Legal hold:** any litigation, regulator inquiry, or breach investigation triggers a hold flag that suspends all deletion and rotation on affected entries until the hold is released by the DPO with two-party approval.
- **Disposal:** at end of retention, entries are cryptographically erased (key destruction) and the disposal is itself logged.

---

## 4. Risk Register Integration

### 4.1 DengueSense Risk Register — Security-Relevant Risks

The programme risk register (DengueSense §10) tracks 15 risks (R1–R15), reviewed fortnightly and at every stage gate. The security- and privacy-material risks, with explicit integration into this document's controls:

| Risk | Description (from §10) | Likelihood / Impact | Security Controls in this Doc |
|---|---|---|---|
| **R3** | Model learns site, device, or treatment artefacts (data integrity threat) | Medium / Critical | §2.2, §2.8 — provenance tracking, anomaly detection, signed artefacts, site-held-out validation, spectral weight analysis |
| **R5** | Data leakage from repeated scans | Medium / High | §1.2 minimisation; patient-level splits (Document 03); feature-availability timestamps; input-hash dedup in audit log |
| **R8** | Overclaiming by sales or partners | Medium / High | §3 audit logging of all claims-material artefacts; model-card version pinning; release-engineering sign-off; approved-claims matrix |
| **R9** | Privacy or security incidents | Medium / Critical | This entire document; §4.3 incident response plan; §1.6 compliance checklist; quarterly tabletop exercise |
| **R11** | Clinician over-reliance | Medium / High | §3 audit of every override; HITL for clinical actions (§2.6); dashboard limitation messaging |
| **R15** | Tongue features reflect confounders not dengue physiology | Medium / High | Provenance + confounder recording (Document 03); independent incremental-value gates; standardised capture (§1.2) |

R3 and R9 receive dedicated attention: R3 is a tampering threat (an adversary could deliberately exploit artefact learning), and R9 is the umbrella risk this document directly mitigates.

#### 4.1.1 R3 — Model Artefact Learning

R3 manifests as the model spuriously learning site lighting, device sensor characteristics, or treatment-team patterns rather than dengue physiology — a **data integrity threat** exploitable by an adversary injecting subtly biased training data. Controls:

- **Metadata analysis** at ingest: every frame's metadata (device, firmware, lighting level) is recorded; before each training run, feature distributions are stratified by metadata and tested for excessive correlation (KL divergence > threshold flags the site).
- **Site-held-out validation** at G5: the model is evaluated on a site that contributed zero training data; performance drop beyond the SAP threshold triggers forensic review.
- **Provenance graph query:** for any flagged artefact, the provenance graph (§2.2) is queried to identify the submitting device and actor; anomalous submission patterns are routed to the red team.
- **Spectral weight analysis:** post-training, weight-matrix singular values are compared with the prior release; large deviations trigger investigation.

#### 4.1.2 R9 — Privacy or Security Incidents

R9 is the umbrella risk addressed by this document. The §10 mitigations — pseudonymisation, least privilege, encryption, rehearsed response plans — are operationalised throughout §1–§3 and exercised in §4.3.

### 4.2 Risk Review Cadence

Per §10, the risk register is reviewed **fortnightly** and at **every stage gate (G0–G8)**. Security-relevant risks are additionally reviewed by the Privacy and Security Review Body (monthly during build, quarterly thereafter per §11). Critical risk acceptance requires authorisation at the appropriate governance level — a technical owner cannot unilaterally accept R9.

### 4.3 Incident Response Plan

The incident response plan follows the standard five-phase lifecycle and is rehearsed annually (tabletop) and after every major change (red-team/purple-team exercise).

```
                 +-----------------------+
                 | 1. DETECTION          |
                 |  - SIEM alerts        |
                 |  - Audit log anomaly  |
                 |  - User report        |
                 |  - Bug bounty / 3rd   |
                 |    party disclosure   |
                 +----------+------------+
                            |
                            v
                 +----------+------------+
                 | 2. CONTAINMENT         |
                 |  - Isolate affected   |
                 |    service/account    |
                 |  - Revoke tokens      |
                 |  - Rotate keys        |
                 |  - Block IPs / devices|
                 |  - Snapshot forensic  |
                 |    state              |
                 +----------+------------+
                            |
                            v
                 +----------+------------+
                 | 3. ERADICATION         |
                 |  - Remove malware     |
                 |  - Patch root cause   |
                 |  - Validate integrity |
                 |    (Merkle root,      |
                 |     model signatures) |
                 +----------+------------+
                            |
                            v
                 +----------+------------+
                 | 4. RECOVERY            |
                 |  - Restore from clean |
                 |    backup             |
                 |  - Re-deploy signed   |
                 |    artefacts          |
                 |  - Re-enable service  |
                 |    under monitoring   |
                 |  - Communicate with  |
                 |    sites & clinicians |
                 +----------+------------+
                            |
                            v
                 +----------+------------+
                 | 5. POST-INCIDENT      |
                 |    REVIEW             |
                 |  - Blameless RCA      |
                 |  - Update threat      |
                 |    model & controls   |
                 |  - File regulator     |
                 |    notification      |
                 |    (PDPA 72h if       |
                 |    breach)            |
                 |  - Update risk reg.   |
                 +-----------------------+
```

Notification triggers:
- **Internal-only incident** (no PHI exposed): Privacy Officer informed within 24 hours; no external notification unless escalated.
- **PHI exposure to unauthorised internal party:** DPO informed within 12 hours; Privacy and Security Review Body convened within 48 hours; participant notification plan drafted.
- **PHI exposure to external party / public:** JPDP notification within 72 hours per PDPA 2024 Amendment; participant notification per regulator guidance; NMRR/MREC informed; for MoH-resource incidents, NIH Malaysia informed per data-access policy.

### 4.4 Security Deployment Checklist (Vibe Coding §15.2)

The Vibe Coding §15.2 checklist is the operational baseline that every DengueSense deployment — staging, UAT, production — must satisfy before a stage gate is passed. Each item is verified by the release engineer and signed off by the Security Officer.

| # | Security Item | Implementation | Verification |
|---|---|---|---|
| 1 | HTTPS enabled | Certbot with auto-renewal; TLS 1.3 only; HSTS preload | `certbot renew --dry-run` passes; SSL Labs A+ |
| 2 | Security headers | X-Frame-Options: DENY; X-Content-Type-Options: nosniff; CSP strict-dynamic + nonce; HSTS max-age=63072000; Referrer-Policy; restrictive Permissions-Policy | `curl -I` check in CI; Mozilla Observatory A+ |
| 3 | SSH key authentication | Password auth disabled; key-only; root login disabled; rate-limited SSH | `sshd_config` lint; failed-login test |
| 4 | Firewall configured | UFW allowing only 80, 443, and SSH port (moved off 22) | `ufw status verbose`; external port scan (nmap) |
| 5 | Database not exposed | DB bound to localhost or private subnet; no public ingress; pooling behind API | `netstat -tlnp`; external scan shows no DB port |
| 6 | Environment variables | All secrets in `.env` or Vault/KMS; `.env` in `.gitignore`; pre-commit secret scan | gitleaks clean; manual repo review |
| 7 | Automatic updates | `unattended-upgrades` for security patches; reboot window scheduled; kernel live-patching where supported | `/var/log/unattended-upgrades/` review; pending-reboot alert |
| 8 | Rate limiting | Nginx `limit_req` (10 r/min inference, 60 r/min dashboard) + application-level limits + per-device cap | Load test confirms 429 under abuse |
| 9 | Backup automation | Daily automated backups with tested restore; encrypted; off-region copy | Quarterly restore drill; RPO/RTO met |
| 10 | Intrusion detection | Fail2ban blocks repeated SSH/auth failures; AIDE file integrity monitoring; auditd rules | Fail2ban log review; AIDE diff review |
| 11 | Audit log integrity | Hash-chained, signed, WORM storage; Merkle root published hourly | Daily integrity script; quarterly external audit |
| 12 | Container hardening | Read-only root FS, dropped capabilities, seccomp, non-root user, Pod Security Admission restricted | kube-bench clean; kube-hunter clean |
| 13 | Supply-chain security | Snyk/OSV (SCA) + Semgrep (SAST) on every PR; OWASP ZAP (DAST) nightly against staging; Cosign/Sigstore model signatures; mTLS via service mesh; ops logs separated from audit log | CI status; Cosign verify in deploy script; service mesh audit |

Any "Not Verified" item blocks the corresponding stage gate. The checklist is reproduced as a CI-gated artefact (signed JSON) attached to every release.

---

## 5. Closing Notes

This document is the security and compliance baseline for beAIve DengueSense. It is not static: as the threat model evolves (new agentic modules in Document 02, new data streams in Document 03, new deployment topologies in Document 05), §2 (threat model) and §3 (audit logging) must be re-evaluated at every stage gate. The Privacy and Security Review Body holds final authority over residual risk acceptance; any deviation from this baseline requires their written approval before deployment. Integration with the risk register (§4.1) ensures security decisions are reflected in the RAID log and reviewed at the same governance cadence as clinical, technical, and regulatory risks.

Next actions: (1) complete the DPIA before G3; (2) execute the pre-deployment pentest at G3 with zero Critical/High open; (3) hold the first annual tabletop incident-response exercise before multi-site rollout; (4) take Merkle root publication live with the first production audit-log write.
