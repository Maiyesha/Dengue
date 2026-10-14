# DengueSense iOS Ward Capture App — Design

**Status:** Draft for approval · **Date:** 2026-10-13 · **Phase:** A (clinician research capture)
**Classification:** Research Use Only (RUO), not a medical device claim
**Sources:** `01`–`06` spec suite in this folder's project root; research report `reports/DengueSense iOS capture research.md`

---

## 1. Intent and why

Nurses on dengue wards already watch patients through serial vitals and blood tests (FBC, haematocrit, platelets). DengueSense is a research programme testing whether a short, contactless or near-contactless smartphone capture can **one day** add useful signal about deterioration. Before that question can be answered, the programme needs **clean, standardised, auditable recordings** collected at the bedside alongside routine care.

This app is that recording tool. Its job is to help a nurse capture a good-quality recording quickly, tell them honestly whether it is usable, and send it securely for research analysis, **without ever influencing the patient's care.**

Success: on a busy ward, a nurse completes a usable capture in under ~3 minutes, including setup, ≥90% of the time (doc 01 G1 criterion). The app never shows anything a nurse could mistake for a dengue result.

## 2. Users and setting (from the scenario)

- **Operator:** a nurse or trained healthcare worker holding an iPhone (or a ward iPad).
- **Patient:** an adult with suspected or confirmed dengue lying on a hospital bed, often febrile, possibly tachycardic, lethargic, or vomiting. They may be lying flat or semi-reclined.
- **Environment:** a Malaysian hospital ward with fluorescent or LED lighting on 50 Hz mains, windows with daylight, nearby monitors, noise and interruptions, and patchy Wi-Fi.
- **Reviewer:** a study clinician (doctor or research nurse lead) who reviews sessions later on the app or the research dashboard.
- **Consent:** obtained beforehand through the study's MREC-approved process (paper or e-consent), outside this app.

## 3. Goals, non-goals, anti-goals

**Goals**
1. Guide the nurse through a standardised capture of the patient's face and/or fingertip, plus the protocol's optional eye and tongue steps.
2. Check quality live and after capture. Ask for a recapture with a plain reason, or record "unable to acquire" after the allowed attempts.
3. Work offline at the bedside. Store securely and upload later.
4. Record reference measurements from the hospital's own validated devices at the same time, so research can compare against them.
5. Let a study clinician review and sign off each session.
6. Write a complete audit trail.

**Non-goals (Phase A)**
- Producing any risk score, probability or risk band. The Risk Engine (M8) has not passed its locked-validation gate, so the app does not call `POST /assessments` and shows no M8 output.
- Patient self-use or home use (that is Phase B and stays research-only; see §15).
- Face recognition or identity verification by face.
- Optical haematology (M7) estimates of Hb, Hct or platelets.

**Anti-goals (failure even if it "works")**
- Any screen, notification, export or wording that suggests the camera detected, ruled out, or graded dengue, or that a value can stand in for a blood test or a nurse's assessment.
- A nurse delaying or skipping standard observations or labs because of the app.
- Experimental camera numbers presented in a way that could steer care: without the "Experimental — not validated" label, as an alarm, in red/amber, with thresholds, or as a replacement for the monitor value (doc 01 §1.3: unvalidated components "must not influence care"). Showing them **at all** at the bedside is a decision by the product owner (2026-10-13) and is gated by §5a.
- Patient identity (name, IC/NRIC, MRN, face thumbnails) visible in the app or stored on the device.
- Forcing a result from a poor recording.

## 4. Claim and language rules (binding on all UI copy)

- **Persistent banner** on every patient-related screen: *"Research Use Only — not for diagnosis or treatment decisions. Continue standard care and blood tests."*
- **Forbidden words in the UI:** diagnose, diagnosis, detect dengue, positive, negative, severity, safe, normal, abnormal, risk (until M8 passes G6/G7), and "result" applied to the patient. Use **"capture quality"** and **"recording"** instead.
- The completion screen says *"Recording saved for research"*. It never says "result ready".
- CI lint enforces this: a string-catalog test fails the build if a forbidden term appears in any user-facing string. (This is my call; the doc 02 approved-claims matrix is the governing source.)

## 5. Three tiers of measurement (must be visually distinct)

| Tier | What it is | Examples | Where shown | Status shown in UI |
|---|---|---|---|---|
| **R: Reference (validated devices)** | Values the nurse reads from the hospital's own monitor, thermometer or lab system and types in | HR from bedside monitor or pulse oximeter, BP, SpO₂, temperature, RR, CRT; latest Hct/platelets with collection time | Nurse's entry screen; clinician review | "From hospital device", with the device type recorded |
| **Q: Capture-quality checks (engineering)** | Software checks on whether the recording is usable. They say nothing about the patient's health | Face found, motion, head angle, distance, lighting level, flicker risk, frame rate and dropped frames, duration, finger coverage, focus, colour-card visible | Live guidance and the quality screen | "Recording quality", shown as pass/fail per check with a reason |
| **X: Experimental research signals** | Camera-derived physiological features under study, **not validated** (the rPPG module is at gate G2 analytical validation; others are earlier) | Camera pulse rate (face), camera pulse rate (fingertip), HRV, perfusion/colour indices, eye and tongue colour features | **Bedside:** face and fingertip camera pulse rates only, under the §5a rules. **Dashboard:** all X features for researcher and clinician roles | "Experimental — not validated — do not use for care" |

### 5a. Bedside display of experimental values (decided by the product owner, 2026-10-13)
The product owner chose to show experimental values to the nurse, clearly labelled. Rules:
- **Gate:** a protocol-config flag `show_experimental_at_bedside`, default **off**. It is switched on per site only after MREC approval of the amended protocol and Clinical Steering Committee sign-off (doc 02 §3.2: a clinician-visible release is human-in-the-loop). Until then the app behaves as if the flag were off.
- **What is shown:** the face and fingertip **camera pulse rate**, rounded to whole bpm. Colour, perfusion, HRV and eye/tongue indices stay dashboard-only (my call: they have no bedside meaning, and units nurses can't interpret invite misreading).
- **Where and when:** on the session's "Recording saved" detail, only after the server has computed the values from the authoritative pipeline (never the on-device preview, which is not reproducible). They are listed **below** the nurse's own monitor value, which is always shown first and larger.
- **How:** a grey "EXPERIMENTAL" chip, the text *"Not validated — do not use for care decisions. Use the monitor value."*, neutral colour only, no arrows, no ranges, no alerts, no notifications containing values, and no trend charts at the bedside.
- **Never:** in push notifications, exports, printouts, or the patient's clinical record.
- **Audit:** each time X values are displayed, a `view_experimental` audit event is written, so research can later study whether display influenced care.
- **Research impact:** the protocol and statistical analysis plan must record that operators were unblinded to camera pulse rate from the date the flag goes on. Flag on/off dates per site are logged.

## 6. End-to-end workflow

```
Sign in ─▶ Select patient (study ID) ─▶ Consent check ─▶ Pre-capture checklist
   ─▶ Reference vitals entry ─▶ Capture steps (guided) ─▶ On-device quality check
   ├─ ACCEPT ─▶ Seal & queue ─▶ Upload (now or later) ─▶ Server quality check (authoritative)
   │                                      ├─ server PASS ─▶ Research processing ─▶ "Recording saved for research"
   │                                      └─ server FAIL ─▶ Nurse notified: recapture requested (if patient still available)
   ├─ RECAPTURE (≤2 per step) ─▶ back to that step
   └─ UNABLE TO ACQUIRE ─▶ reason recorded, session closed
 ─▶ Clinician review & sign-off (later) ─▶ Archived
```

### 6.1 Sign in
- Hospital SSO (OIDC + PKCE via `ASWebAuthenticationSession`) with a passkey or MFA. The session times out after 10 minutes idle and requires Face ID/passcode to resume (timeout value is my call).
- Roles on device: `nurse_operator` (a capture-only subset of doc 04 `clinician`) and `clinician` (adds review). Researchers use the web dashboard, not the app.
- One supervised device per ward, not Shared iPad mode (the research found Shared iPad sign-out can delete unsent recordings). Clinicians switch users inside the app, and uploads run on a device credential.

### 6.2 Select patient
- Scan the study-ID barcode on the patient's wristband or study card, or type the ID. Only the **study ID** and **bed number** appear on screen. No name, NRIC or MRN.
- The app shows the patient's last capture time to avoid duplicates (the server rejects a new scan within 30 min with 409, per doc 04).
- New-patient enrolment is a study-coordinator task in the web system. The app cannot create patients (my call; it keeps identifiers off the phone).

### 6.3 Consent check (blocking)
- The app fetches the consent status for the study ID and requires: `primary_research = true`, a current consent version, and not withdrawn. Without these the capture is blocked with: *"No valid study consent on record. Do not record. Contact the study coordinator."*
- If the consent version has been superseded (`DS_REG_002`), capture is blocked until re-consent.
- **Per-session assent:** before recording, the nurse confirms: *"Patient (or guardian) has been told a short research video will be recorded now and agrees."* If the patient declines, the nurse taps "Patient declined today", which is logged as a reason. No pressure, no retries.
- Offline: the app uses a consent snapshot cached within the last 24 h, re-validated by the server on upload. If the server finds consent invalid, the upload is quarantined and deleted (§11).

### 6.4 Pre-capture checklist (≈15 s)
A tick-list card, all items required:
- Patient is resting and calm, not mid-vomiting or in rigors. If not, "Come back later".
- Glasses removed if safe; hair off the forehead; mask down only if clinically safe.
- Overhead light on; no strong window light behind the patient.
- Phone holder or clamp fitted (recommended; see §7.1).
- Colour reference card ready (needed for the eye and tongue steps only).

### 6.5 Reference measurements entry (Tier R)
- Fields: HR, SpO₂, BP, temperature, RR, CRT; the source device type for each (pick-list); time measured (defaults to now and is editable).
- Optional: latest Hct, platelets and WBC with their **collection time**. Values taken after the scan are flagged so the server can apply its leakage rules (doc 03 `feature_availability_timestamp`).
- Range validation per doc 03 §2.1. An out-of-range value is flagged `INVALID` and the nurse must confirm or correct it; it is never silently dropped.
- Ideally the nurse takes monitor HR/SpO₂ **during** the face/finger recording. The app prompts: *"Note the monitor heart rate now"* at the 20 s mark.
- This screen is skippable only with a reason ("monitor unavailable"), because comparison data is the research's backbone.

### 6.6 Capture steps
Which steps run is set by the **study protocol configuration** pushed from the server (`capture_protocol` version). The nurse cannot change it. Defaults:

| # | Step | Mode | Duration | Notes |
|---|---|---|---|---|
| 1 | Identity check | Study ID confirmed | ~5 s | Already done in §6.2; re-confirm on the capture screen |
| 2 | Positioning & lighting | Front camera, live guidance | 5–10 s | All guidance indicators green for 2 s before recording starts automatically |
| 3 | Neutral face | Front camera video | 30–45 s | Primary rPPG and perfusion recording. Patient still, eyes open, no talking |
| 3F | **Fingertip** (**required**, decided by the product owner) | Rear camera + torch, finger over lens | 30 s | New modality from the ward scenario; see §7.3 and §16. Runs right after step 3 |
| 4 | Eye (conjunctiva) | Rear camera, colour card in frame | ~10 s | Protocol-optional. Nurse gently asks the patient to look up; **no touching the eyelid** unless the protocol allows it |
| 5 | Dorsal tongue | Rear camera, colour card | 10–15 s | Protocol-optional; exploratory module M6 |
| 6 | Controlled task | — | ~10 s | Off by default (only if the protocol justifies it) |
| 7 | Quality result | — | immediate | See §8 |

Each step has a big "Start" button and live guidance. Recording auto-stops at the target duration. The nurse can **pause** (patient coughs, someone walks in), which discards that step's partial recording and restarts the step without counting it as a recapture attempt.

## 7. Camera guidance

### 7.1 Supine patient positioning
- Recommended: a bed-rail or flexible-arm phone holder about 40–60 cm above the face, so the nurse's hands are free and the camera stays still. Handheld is allowed but gives more motion failures; the app records `mount = handheld | holder`.
- **On-screen face frame:** an oval overlay. Green when the face is centred and filling 40–60% of the frame width.
- **Distance:** TrueDepth depth data gives a live "Move closer / Move back" cue (target 20–80 cm; ideal 40–50 cm).
- **Head angle:** Vision yaw/pitch/roll within ±15°. Cue: *"Tilt the phone to match the patient's face"*. For a lying patient the phone is moved, not the patient.
- **Lighting:** an estimated scene brightness check (≥200 lux equivalent), plus a glare/shadow check over forehead and cheeks. Cues: *"Too dark — turn on overhead light"*, *"Bright light behind — move the phone or close the curtain"*.
- **Stillness:** a motion meter. Cue: *"Hold still"* for the phone, *"Ask the patient to rest still and not talk"* for the patient.
- Voice prompts are optional (off by default; the microphone is never used, playback only).
- Guidance uses icons + short text + colour + haptics, so it is not colour-only and stays readable at arm's length (large type, WCAG 2.1 AA contrast).

### 7.2 Camera configuration (fixed, not user-adjustable)
From the research report:
- Custom `AVCaptureSession` (not ARKit). Frame rate locked at 30 fps (`activeVideoMin = MaxFrameDuration`).
- Exposure: custom mode with exposure time **1/100 s or 1/50 s** (multiples of 10 ms) to suppress 50 Hz-mains flicker. ISO chosen during the positioning step, then locked.
- White balance and focus locked at the end of positioning. Video HDR, local tone mapping, Center Stage, stabilisation, Portrait/Studio Light and other system video effects are **off**.
- After configuring, the app **reads every setting back**. If any differs (the OS can reset them on format change), the capture is aborted with an engineering reason code and the nurse sees *"Camera not ready — try again"*.
- No photo output in the session (it can override exposure locks). No audio input, so iOS never asks for microphone permission.

### 7.3 Fingertip mode (from the ward scenario)
- The rear camera with the torch on, at the lowest torch level that gives a good signal (to limit heat). The patient's (or nurse-assisted) index fingertip covers both the lens and the torch.
- Guidance: *"Cover the camera and light completely with the fingertip. Rest the hand on the bed. Don't press hard."* A live coverage indicator shows the frame is saturated red with no edges of light. A pressure proxy watches for the signal flattening.
- 30 s recording. Quality checks: coverage, clipping/saturation, motion, signal periodicity.
- **Tier status:** fingertip camera pulse is an experimental (X) signal in this programme until it passes its own analytical-validation gate, even though contact PPG is better studied than face video. At the bedside it follows §5a.
- **Spec gate:** fingertip is required by design, but it changes the data dictionary (§16.1). Code is built now. Deployment to any study site is blocked until Biostatistician + Regulatory sign-off of the schema change is recorded.
- Hygiene: wipe the phone with the ward's approved disinfectant between patients. The app shows a reminder on session close.

### 7.4 Eye and tongue steps
- The colour reference card must be in frame. The app detects the card and checks ΔE against its calibration; if the card is missing it says *"Show the colour card next to the eye/tongue"*.
- Torch policy: off for the eye step (comfort and safety). The protocol decides for the tongue step.

## 8. Quality checks

Two layers: **on-device provisional** (instant feedback at the bedside) and **server authoritative** (decides what enters research). Codes follow doc 04 §3.3.

| Check | On device (live + post-step) | Server (authoritative) | Reason code → nurse instruction |
|---|---|---|---|
| Face detection & stability | Vision face rect/landmarks, ≥90% frames conf ≥0.9 | Recompute | `DS_QG_003` occlusion / face lost → "Keep the whole face in the oval" |
| Motion & head pose | Landmark jitter, yaw/pitch/roll ±15° | Recompute | `DS_QG_001` → "Use the holder; ask the patient to rest still" |
| Exposure & lighting | Luma band, clipped pixels, colour temperature drift | Recompute | `DS_QG_002` → "Turn on overhead light / avoid light behind patient" |
| Frame rate & gaps | Sample-buffer timestamps: no gap >0.5 s, <5% missing | Recompute from container | `DS_QG_004` → "Close other apps and try again" |
| Pulse-signal plausibility (face/finger) | Simple POS/CHROM preview: spectral peak in 0.7–3.5 Hz, SNR estimate (used **only** as a pass/fail gate; the number is never displayed) | Full SNR + spectral plausibility | `DS_RPPG_001/002` → "Keep still for the full time; check lighting" |
| Occlusion | Forehead/cheek ROI visibility | Recompute | `DS_QG_003` |
| Eye segmentation | Core ML seg model, mask IoU proxy ≥0.6 | Recompute | `DS_SEG_001` → "Ask patient to look up; show the colour card" |
| Tongue segmentation + focus + card ΔE | Seg model, Brenner focus, card ΔE | Recompute | `DS_SEG_001` |
| Duration & missing frames | Timer + timestamps | Recompute | `DS_QG_004` |
| Finger coverage (3F) | Red saturation, edge light leak, clipping | Recompute | new `DS_QG_005` (needs adding to the reason-code catalog) |

**Quality screen (step 7):** a per-step list with a ✓ or a ✗ and a one-line reason with an instruction. The overall status is shown in words: **"Good recording"**, **"Please record step N again"** or **"Could not record — reason saved"**. The quality *score* is not shown to the nurse (my call; it invites over-interpretation). Reviewers can see it.

**Recapture rules:** at most 2 recaptures per step (doc 03 §2.4). After that the step is marked `UNABLE_TO_ACQUIRE`. **Both face (step 3) and fingertip (step 3F) are core**, as decided by the product owner. A session counts as usable only if both pass. If either core step fails after its recaptures, the session ends as an acquisition failure (the other step's good recording is still uploaded, marked `partial`, for research on failure modes): *"Could not get a usable recording today. This is common and not a problem for the patient. Reason saved."* Optional steps can fail without failing the session (my call).

**Device vs server disagreement:** if the server fails a recording the device accepted, the nurse gets an in-app notice (no PHI in the push text): *"Recording for study ID ••417 needs repeating (lighting)."* It offers "Record again" if within the protocol time window (default 2 h, my call), otherwise it closes as an acquisition failure. Disagreement rates are tracked as a metric to tune the on-device checks.

## 9. Processing and edge-vs-server split

| Runs on iPhone | Runs on server |
|---|---|
| Camera control, live guidance (Vision, TrueDepth) | Authoritative 9-check quality gate |
| Provisional quality checks (§8) | rPPG, perfusion, eye and tongue feature extraction (Tier X) |
| Small Core ML segmentation models for eye/tongue/card (≈5 ms/frame class) | Any future Risk Engine (M8), only after its gates; not in Phase A |
| ROI colour-trace extraction **before compression** (lossless, <2 MB/session) | Model registry, versioning, reproducibility to 6 d.p. |
| Encryption, queueing, upload | Audit log, research dashboard |

Why: on-device ML is not bit-reproducible across devices and OS versions, and locked research models must be reproducible and auditable. Keeping models on the server also keeps them out of App Review and protects the IP. The phone gives speed; the server gives truth.

**Upload artefacts per step:** ROI traces (lossless), HEVC video at ≥20 Mb/s (ProRes 422 optional on Pro iPhones if the protocol asks), and capture metadata (doc 03 `ContextualMetadata`: device model, fps, resolution, exposure, distance, angle, lux, mount, lighting type, ambient temperature/humidity if entered).

## 10. Screens and states

| Screen | Key states |
|---|---|
| Sign-in | loading, SSO error, offline (cached session valid for ≤12 h, my call) |
| Ward list / patient select | empty ("Scan a study ID"), patient found, not found, consent blocked |
| Consent & assent | valid, missing, superseded, declined-today |
| Checklist | incomplete, complete |
| Reference vitals | empty, partial, out-of-range warning, skipped-with-reason |
| Capture (per step) | positioning (guidance), ready, recording (countdown ring), paused, step done |
| Quality result | all good, recapture needed (with reason), acquisition failure |
| Saved | "Recording saved for research", plus upload status: queued / uploading / sent / needs repeating |
| Outbox | per-session upload status, retry, storage used; no patient identifiers |
| Review queue (clinician) | pending, reviewed, flagged |
| Settings | protocol version, device check, app version, help, sign out |

All screens carry the RUO banner. Loading, empty, error and offline states are designed for every screen (doc 02 frontend prompt).

## 11. Error handling

| Situation | App behaviour |
|---|---|
| Camera permission denied | Explain why the camera is needed; link to Settings; capture blocked |
| Phone too hot / thermal pressure | Stop recording, discard the step, *"Phone is warm — wait a minute"*; log `system_pressure` |
| Low storage (<2 GB free) | Block new captures until the outbox clears; show the outbox |
| Low battery (<15%) | Warn; block at <5% |
| Interrupted (call, app switch, lock) | Discard the partial step; resume at the same step |
| No network | Capture continues; recordings queue; banner "Will upload when connected" |
| Pre-signed URL expired | Re-request a URL for that part; resume the multipart upload |
| Server 409 (recent scan) | *"This patient was recorded in the last 30 min"* |
| Server 422 quality fail | Recapture notice (§8) |
| Server 451 regulatory hold / consent superseded | Stop; quarantine recordings for that patient; notify the coordinator |
| Consent found invalid after upload | Server rejects; device deletes local copies by destroying their keys; audit event |
| Audit writer down (`DS_AUD_001`) | Server refuses; device keeps the item queued and retries with backoff |
| Unhandled crash | Crash report has no PHI; partially recorded steps are discarded on relaunch |

## 12. Offline behaviour
- Everything up to "Recording saved" works offline: sign-in (cached ≤12 h), patient lookup (cached ward roster of study IDs only), consent snapshot (≤24 h), capture, on-device quality and encryption.
- The outbox is a SQLite table (GRDB). Each item stores its `Idempotency-Key` (created once), artefact hash, and wall-clock, monotonic and server-offset timestamps.
- Uploads use background `URLSession` S3 multipart, with per-part pre-signed URLs minted just before each part.
- Recordings are deleted from the device (key destroyed) once the server confirms receipt and the hash matches. Anything still unsent after 7 days alerts the ward lead (my call).

## 13. Privacy and security
- **On screen:** study ID and bed only. The camera preview is shown live but no face thumbnails are kept in lists. Screen recording/mirroring is detected and blurs the screen, and the event is logged (iOS cannot block screenshots).
- **On device:** files are written with Data Protection Class B while recording, then sealed with AES-GCM using a Secure-Enclave-wrapped key and stored at Class C for background upload. They are excluded from backups and iCloud. Deletion means destroying the key.
- **Device trust:** App Attest key at enrolment; a server-challenged assertion refreshes a 24 h device-trust token, and the refresh token is bound to the App Attest key.
- **Network:** TLS 1.3, certificate pinning on API, auth and attest hosts (not S3), and data residency in Malaysia.
- **Minimisation:** no audio, no GPS, no contacts or photos access. No face recognition. Video trimmed to the step window.
- **Distribution:** TestFlight (external, approved study devices) and MDM-supervised hospital devices via Apple Business Manager. The privacy manifest declares the required-reason APIs.

## 14. Clinician review
- **Review queue** (clinician role, in the app or on the dashboard): sessions from their own site, showing quality per step, recapture history, operator notes, and the Tier R reference values entered.
- Actions: **Confirm protocol followed**, **Flag deviation** (pick-list: wrong position, patient distressed, consent concern, other + note), **Request repeat**, **Exclude from research** (with reason).
- In-app review shows Tier X camera pulse rates next to the reference values, under the same §5a rules and labelling. Researchers see all X features in the dashboard.
- Sign-off moves the session to `ARCHIVED` (doc 01 §3.2 REVIEW → ARCHIVED). Every action is audit-logged and bound to the clinician's passkey.
- Clinical endpoint adjudication is a separate committee process and never sees model output (doc 03 label independence). The app plays no part in it.

## 15. Phase B (consumer self-screening): research only
Per the research report, there is currently no validated camera method to detect or grade dengue. Apple 1.4.1 would require regulatory clearance; in Malaysia the product would likely be MDA Class C; at the FDA, a De Novo. Phase B stays as evidence and regulatory planning. This app's codebase must not contain a consumer mode, home-use flow, or self-assessment screen.

## 16. Required changes to the existing specs (human-in-the-loop per doc 02 §3.2)
1. **Fingertip modality:** add `fingertip` to `capture_type` (doc 04) and `fingertip_ppg` to the `capture_steps.step_name` enum (doc 03). Add feature schema, the `DS_QG_005` reason code, and a data-dictionary entry. Needs Biostatistician and Regulatory sign-off.
2. **`nurse_operator` role:** a capture-only subset of `clinician` (doc 04 §2.2).
3. **Reference-device fields:** source device type and time for each Tier R vital in `clinical-data`.
4. **Capture metadata:** `mount`, `lighting_type`, `exposure_duration_ms`, `device_vs_server_quality_agreement`.
5. **`capture_protocol` config endpoint:** serves which steps are enabled per site and protocol version.

## 16a. Server interfaces this app needs (my calls; built in the same plan)
The backend (DB schema + `/v1` API) is **in scope** of the same implementation plan (approved plan, Step 3). These extend doc 04:

1. **Identifiers:** the wristband/study card carries the **participant study code** (e.g. `DS-UKM-00417`, doc 06 §1.3), not the protocol number. Add `GET /v1/patients/lookup?participant_code=` (returns `pat_…` id, bed, last scan time; no direct identifiers) and `GET /v1/wards/{ward_id}/roster` for the offline cache (study codes + bed + consent snapshot only).
2. **Consent:** `GET /v1/patients/{id}/consent-status` returns `{primary_research, consent_version, current_version, withdrawn, checked_at}`. The `nurse_operator` role may call lookup, roster and consent-status, `POST /scans`, `/recapture`, `clinical-data`, and upload endpoints. It never sees direct identifiers.
3. **Offline scan creation:** the device generates a `client_session_id` (UUID v4) at capture time. `POST /scans` is called when online, ideally **before** recording (pre-registration), or else at upload time, with `client_session_id` + `captured_at` + `offline=true`. The server applies the 30-min, consent and regulatory rules at that point. If it refuses a recording made offline, the device destroys the artefact keys, writes a `capture.rejected_post_hoc` audit event, and shows the nurse why. The 30-min duplicate rule uses `captured_at`, not the upload time.
4. **Uploads:** add `POST /v1/scans/{id}/artefacts` (declare an artefact: step, attempt, kind = `video|roi_trace|metadata`, size, sha256) → `{artefact_id, upload_id}`. Then `POST /v1/artefacts/{id}/parts/{n}/url` mints one pre-signed part URL (900 s), and `POST /v1/artefacts/{id}/complete` makes the server verify the sha256 and return `received_verified`. The device deletes its copy only after `received_verified` for every artefact in the session.
5. **Server quality check:** runs **automatically** (system_agent) when all core artefacts are verified. The app learns the verdict by APNs push (no PHI in the payload; text like "A recording needs repeating") plus polling `GET /scans/{id}` when the app is foregrounded. Add `POST /v1/devices/push-token`.
6. **Recaptures:** `POST /scans/{id}/recapture` gains `steps: [...]`, so only the failed steps get new artefact slots. The server counts attempts **per step** (max 2). Bedside recaptures made offline are uploaded as `attempt` 2/3 artefacts of the same scan, so no extra recapture calls are needed.
7. **Reference vitals:** sent as `POST /patients/{id}/clinical-data` with a client-generated `observation_id` and `scan_client_session_id`. The server de-duplicates on `observation_id`, which makes queued retries safe (an amendment to doc 04 §3.6's no-auto-retry rule). New fields per vital: `source_device_type`, `measured_at`.
8. **Clinician review:** add scan statuses `review_pending → reviewed | flagged | excluded → archived`. Add `POST /v1/scans/{id}/review` with `{action: confirm|flag|request_repeat|exclude, reason_code, note}` and a WebAuthn assertion over the request hash.
9. **Auth:** Clerk stays the identity provider (doc 01 TRD). Hospital SSO is federated through Clerk enterprise connections, and passkeys go through Clerk. The app uses OIDC + PKCE via `ASWebAuthenticationSession`. App Attest: `POST /v1/devices/attest` (enrolment) and `POST /v1/devices/assert` (returns a 24 h device-trust token). Background uploads use a **device-scoped token** derived from the attested device, limited to artefact upload endpoints. mTLS applies service-to-service only, not to phones.
10. **Error dispatch:** the app routes on `error.code`, never on HTTP status alone. `DS_REG_001/002` always mean stop, quarantine and notify the coordinator, whether they arrive as 422 or 451.
11. **ML models for eye/tongue/card:** none exist yet. In Phase A those steps ship **disabled by protocol config**. Face (and fingertip, if enabled) quality checks use only Vision and signal processing, with no custom ML.

## 17. Constraints
- Research Use Only until G8. No M8 output in Phase A.
- iOS 17+ (a builder call is fine if it needs 18+). iPhone with TrueDepth front camera; Pro models optional for ProRes.
- The development environment is Windows: Swift code can be written here, but building, signing and device testing need macOS/Xcode (Mac or CI runner).
- Swift + SwiftUI, AVFoundation, Vision, Core ML, CryptoKit, GRDB. No third-party analytics until G3 (doc 01 ADR-07).

## 18. Decided vs left to the builder

**Decided by the product owner (2026-10-13):** face **and** fingertip are both required core steps; experimental camera pulse rates are shown at the bedside with clear labelling, gated per §5a.

**Decided (by the scenario and specs):** nurse-operated, patient in bed, quality-gated with recapture, research-only output, no dengue diagnosis or severity, labs and standard care continue, consent required, clinician review, the doc 04 API, server authoritative.

**My calls (marked above; check these):** only pulse rates (not colour indices) shown at the bedside, from the server only, behind an off-by-default flag; quality score hidden from the nurse; server interfaces in §16a; eye/tongue steps disabled until models exist; no patient creation in the app; no Shared iPad; optional steps can fail without failing the session; 2 h server-recapture window; 10-min idle lock; 12 h offline sign-in; 7-day unsent alert; CI forbidden-words lint.

**Left to the builder:** module/package structure, SwiftUI architecture (e.g. TCA vs MVVM), exact Core ML models for eye/tongue/card segmentation (to be trained; the existing `dengue_seg/best.pt` detects mosquito breeding sites in aerial images and is **not** usable here), visual styling within the WCAG and RUO-banner rules, and test harness design.
