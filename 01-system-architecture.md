# 01 — System Architecture & Core Design Specification

**Project:** beAIve DengueSense × Vibe Coding — Integrated Multimodal Clinical Risk-Assessment Platform
**Document Type:** Technical Documentation — Architecture Specification
**Version:** 1.0 (Baseline for System Design Review)
**Scope:** Combined system architecture unifying the Vibe Coding agentic design/development framework with the beAIve DengueSense domain model

---

## 1. Overview & High-Level Topology

The combined system described in this specification fuses two complementary frameworks into a single operational architecture. From the **beAIve DengueSense** programme (reAInmaker SDN BHD, v2.1, August 2026) the system inherits its clinical domain model: a multimodal, camera-based, contactless risk-assessment pipeline intended to identify patients with dengue at increased risk of clinically meaningful deterioration within a prespecified time window. From the **Vibe Coding** methodology (Dr. Abishek Murugan, v2.0, June 2026) the system inherits its engineering model: an agentic, AI-augmented development workflow built on six pre-code documents, a "Day One Stack," and ten ready-to-use AI agent prompt packs that together govern how the platform is designed, built, tested, and deployed.

The architectural premise is straightforward: a clinically rigorous medical device platform — one that must satisfy analytical validity, clinical incremental value, and real-world validation in sequence — cannot be delivered through ad-hoc, monolithic engineering. It requires the disciplined, document-first approach of Vibe Coding's six pre-code artifacts (PRD, TRD, App Flow, UI/UX Brief, Backend Schema, Implementation Plan) used as the *source of truth* for AI coding agents, and it requires the modular, stage-gated functional decomposition of DengueSense's nine modules and three-layer validation framework. The combined topology treats the six Vibe Coding documents as the *architectural design foundation* and the nine DengueSense modules as the *runtime processing foundation*; the agentic orchestration layer bridges the two, providing both development-time and operational-time AI assistance while preserving auditability for regulatory submission.

### 1.1 Architectural Layers (Top to Bottom)

The system is organized as seven vertically stacked layers, each with a defined boundary, contract, and set of stage-gate exit criteria. Information flows downward through capture, quality gating, multimodal feature extraction, risk fusion, and presentation; agentic and governance concerns are cross-cutting, intercepting every layer.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  L7  CLINICAL DECISION SUPPORT OUTPUT                                       │
│      Research Dashboard, clinician-readable view, audit trail, export logs   │
├─────────────────────────────────────────────────────────────────────────────┤
│  L6  AGENTIC ORCHESTRATION LAYER (cross-cutting)                            │
│      Codex (backend) · Claude (UI) · 10 prompt packs · Plan/Reflect loops   │
│      Stage-Gate Governor (G0→G8) · RACI-aware commit gates                  │
├─────────────────────────────────────────────────────────────────────────────┤
│  L5  RISK ENGINE — fusion of approved variables                             │
│      Probability · Risk band · Uncertainty estimate · Calibration            │
│      L1 Descriptive · L2 Penalised LR · L3 Gradient Boosting · L4 DL        │
├─────────────────────────────────────────────────────────────────────────────┤
│  L4  PROCESSING PIPELINE — multimodal feature extraction                    │
│      rPPG Engine │ Facial Perfusion │ Ocular Research │ Tongue/Oral │        │
│      Optical Haematology (experimental RGB/NIR)                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  L3  SIGNAL QUALITY GATE                                                     │
│      Face detection · motion · exposure · rPPG SNR · occlusion · duration   │
│      Output: ACCEPT / RECAPTURE / FAILED + reason code                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  L2  CAPTURE & GUIDANCE — positioning, lighting, motion, distance           │
│      60–100 sec standardized capture · 7-step workflow                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  L1  SENSOR / DEVICE LAYER                                                   │
│      Standardized smartphone / tablet camera · optional NIR module          │
│      Clinical metadata entry · study-ID pseudonymisation                    │
└─────────────────────────────────────────────────────────────────────────────┘
        ▲                                              ▲
        │   Patient video + clinical inputs            │   Agentic feedback / human review
        │   (60–100 sec, 7 steps)                      │   (every layer emits telemetry)
```

### 1.2 The Vibe Coding "Six Pre-Code Documents" as Architectural Foundation

Per the Vibe Coding methodology, AI coding agents are powerful but are not mind readers; the six pre-code documents eliminate ambiguity so that the agent knows — rather than guesses — what stack to use, how screens connect, and where data lives. In the combined architecture these documents are not merely development artifacts; they are *design contracts* that govern runtime behaviour:

- **PRD (Product Requirements Document)** — defines the intended use statement, the primary endpoint (protocol-defined composite of clinically meaningful deterioration within 24 hours, adjudicated without access to the model output), and the explicit out-of-scope list (no diagnosis, no autonomous treatment recommendation, no replacement for clinical judgement).
- **TRD (Technical Requirements Document)** — locks the stack decisions described in Section 4 (Next.js on Vercel, Supabase Postgres, Clerk auth, Codex for backend code generation, Claude for UI), and hard constraints such as Research Use Only classification, encryption in transit and at rest, and patient-level data splitting.
- **App Flow** — defines the seven-step capture workflow (identity check → positioning → neutral face → ocular → dorsal tongue → optional controlled task → quality result) plus post-capture navigation to the Risk Engine and Research Dashboard.
- **UI/UX Brief** — defines the clinician-facing research dashboard aesthetic (audit trail visibility, uncertainty bands, risk-band legend, no decorative elements that obscure data), accessibility targets (WCAG 2.1 AA), and mobile/tablet responsiveness for ward use.
- **Backend Schema** — specifies the pseudonymised patient registry, the scan/session tables, the feature-store tables, the model-registry tables, and the audit-log tables with row-level security policies.
- **Implementation Plan** — sequences the nine DengueSense modules across the 18-month roadmap and maps each phase to a stage gate (G0 through G8).

### 1.3 DengueSense Domain Foundation — Nine Modules and Three-Layer Validation

The DengueSense programme follows a rigorous three-layer validation framework: first, establishing **analytical validity** of camera-derived physiological measurements (does the camera measure what it claims to measure, against reference devices?); second, determining **clinical incremental value** (do those measurements add predictive value beyond routine clinical information?); and third, **real-world validation** of a locked model in a separate cohort without allowing it to influence care. Every architectural decision in this specification is evaluated against these three layers; components that have not passed the relevant layer must not influence care, must not influence their own labels, and must not be presented to clinicians as confirmed.

The runtime surface comprises nine functional modules (Capture and Guidance, Signal-Quality Engine, rPPG Engine, Facial Perfusion, Ocular Research, Tongue/Oral Research, Optical Haematology, Risk Engine, Research Dashboard). Each module is treated as an independently versionable subsystem with its own release condition, evidence package, and gate owner — detailed exhaustively in Section 2. The product remains classified as **Research Use Only** until all applicable ethics, clinical-research, quality-management, and regulatory conditions are satisfied.

---

## 2. Components & Subsystems

### 2.1 The Nine DengueSense Functional Modules

Each module below is documented with its function, research output, and release condition as specified in the source technical documentation. The release condition is binding: a module cannot be promoted from research to clinical-decision-support use until its gate evidence has been independently reviewed.

| # | Module | Function | Research Output | Release Condition |
|---|--------|----------|-----------------|-------------------|
| M1 | Capture and Guidance | Patient positioning, lighting, motion and distance guidance | Standardised video and metadata | Usability and repeatability pass |
| M2 | Signal-Quality Engine | Detect unusable video before inference | Quality score and reason code | Prespecified rejection-performance pass |
| M3 | rPPG Engine | Derive pulse waveform from facial colour changes | Heart rate, timing, morphology and perfusion features | Reference-device agreement pass |
| M4 | Facial Perfusion | Regional colour and temporal perfusion analysis | Forehead/cheek/nose features and asymmetry | Repeatability and bias review pass |
| M5 | Ocular Research | Conjunctival region and temporal ocular features | Colour, pallor/redness, vessel and blink features | Segmentation and reproducibility pass |
| M6 | Tongue/Oral Research | Standardised tongue-region segmentation | Colour, coating, moisture/texture descriptors | Image-quality, annotation, repeatability and incremental-value gates pass |
| M7 | Optical Haematology | Experimental RGB/NIR estimation | Estimated Hb/Hct/platelet-related trends | Separate analytical-validation gate |
| M8 | Risk Engine | Fuse approved variables | Probability, risk band, uncertainty | Locked external-validation pass |
| M9 | Research Dashboard | Present result and audit trail | Clinician-readable research view | Human-factors review pass |

Module M6 (Tongue/Oral Research) is explicitly classified as **exploratory visual phenotyping** and must not imply that tongue colour, coating, or visible oral lesions confirm dengue or predict severity. Module M7 (Optical Haematology) is **experimental** and is subject to a separate analytical-validation gate; it cannot be combined into the Risk Engine until its analytical validity is independently established. Module M8 (Risk Engine) is the only module permitted to emit a probability output, and only after the locked external-validation pass; pre-lock models may be evaluated in development but must not be exposed in the Research Dashboard as anything other than a research-grade signal.

### 2.2 Agentic Orchestration Subsystem

The Agentic Orchestration Subsystem (Layer L6) is the bridge between the Vibe Coding engineering methodology and the DengueSense runtime. It operates in two distinct modes:

**Development-time orchestration.** Per the Vibe Coding Day One Stack, backend code is generated by **Codex** (an AI coding agent that works inside the repository, reads files, runs checks, and iterates), while frontend code is generated by **Claude** (chosen for coherent UI with Tailwind, shadcn/ui, and consistent loading/empty/error/success states). The ten ready-to-use AI agent prompt packs from the Vibe Coding methodology are mapped to specific subsystems:

| Prompt Pack | Primary Consumer | Architectural Use |
|---|---|---|
| Master Prompt Template | Programme Director | Generates the phased implementation plan that maps the 9 modules to the 18-month roadmap |
| Backend Starter Prompt | Codex agent | Bootstraps Risk Engine API, capture-session endpoints, feature-store writes |
| Frontend Starter Prompt | Claude agent | Builds Research Dashboard screens, capture wizard, audit trail view |
| Database Schema Prompt | Codex agent | Generates Supabase migrations for patient registry, scans, features, models, audit |
| Auth Setup Prompt | Codex agent | Implements Clerk auth with role-based access for clinicians, researchers, admins |
| Debug and Fix Prompt | Codex/Claude agents | Smallest-cause root-cause analysis without unrelated refactoring |
| UI Polish Prompt | Claude agent | Senior-product-designer review of dashboard screens |
| Launch Audit Prompt | Both agents | Pre-launch blockers check covering build, auth, mobile, env vars, security |
| Build Plan Prompt | Codex agent | Smallest build plan that reaches a working research version 1 |
| Vercel Deploy Prompt | Codex agent | Production readiness, package scripts, env var verification |

**Operational-time orchestration.** Within the deployed system, agentic patterns are applied to runtime concerns such as capture-session quality diagnostics, dashboard explanation generation, and anomaly triage. The agentic loop operates over four internal states — **planning** (what to capture, what to feature-extract, what to display), **execution** (running the appropriate pipeline stage), **reflection** (evaluating whether the output meets quality, calibration, and audit requirements), and **error-correction** (re-prompting, re-running with adjusted parameters, or escalating to human review). Every agentic action is logged to the audit trail; no agentic action may mutate a model artifact, an endpoint label, or a clinical record.

### 2.3 Predictive Modelling Layers

The Risk Engine (Module M8) hosts a four-level modelling progression. Levels are cumulative: each level must outperform the prior level on the locked evaluation set before it is permitted to be considered as the production model candidate. The progression mirrors DengueSense's statistical and machine-learning plan, ensuring interpretability precedes complexity.

- **Level 1 — Descriptive Statistics and Biomarker Association.** Confirms signal plausibility and identifies confounding. Includes univariate distributions, missingness patterns, and bivariate associations between each candidate biomarker and the primary endpoint.
- **Level 2 — Penalised Logistic Regression.** Establishes a clinical benchmark and an interpretable baseline. Provides odds ratios with confidence intervals, supports feature-selection stability analysis, and serves as the *minimum interpretable model* against which all higher-complexity models must demonstrate incremental value.
- **Level 3 — Tree-Based Gradient Boosting.** Tests non-linear interactions on structured features. SHAP-style attributions are computed for transparency; only the locked hyperparameter configuration may be used for the final evaluation.
- **Level 4 — Temporal and Multimodal Deep Learning.** Operates on the full multimodal feature set including temporal rPPG waveforms and image-derived embeddings. Only permitted after Levels 1–3 are documented, locked, and benchmarked.

Regardless of level, the Risk Engine emits three outputs: a **probability** of the primary endpoint, a **risk band** (low / intermediate / high), and an **uncertainty estimate** (calibration slope and prediction interval). The dashboard must always display all three together; suppression of the uncertainty estimate is forbidden.

### 2.4 System Component Registry (JSON Schema)

The component registry is the single source of truth for which subsystems exist, which version is current, which gate they have passed, and which AI agent owns their implementation. It is consumed by the Agentic Orchestration Subsystem to route tasks and by the Stage-Gate Governor to enforce progression rules.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "DengueSense Component Registry",
  "type": "object",
  "required": ["registry_version", "components"],
  "properties": {
    "registry_version": { "type": "string", "pattern": "^\\d+\\.\\d+\\.\\d+$" },
    "programme": { "const": "beAIve DengueSense" },
    "classification": { "enum": ["Research Use Only", "Investigational", "Cleared"] },
    "components": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "name", "layer", "function", "output",
                     "release_condition", "gate_state", "owner_agent"],
        "properties": {
          "id":         { "type": "string", "pattern": "^M[1-9]$" },
          "name":       { "type": "string" },
          "layer":      { "enum": ["L1","L2","L3","L4","L5","L6","L7"] },
          "function":   { "type": "string" },
          "output":     { "type": "string" },
          "release_condition": { "type": "string" },
          "gate_state": { "enum": ["NOT_STARTED","IN_DEVELOPMENT",
                                    "ANALYTICAL_VALIDITY","CLINICAL_INCREMENTAL",
                                    "REAL_WORLD","LOCKED","RETIRED"] },
          "owner_agent": { "enum": ["codex","claude","human","mixed"] },
          "modelling_levels": {
            "type": "array",
            "items": { "enum": ["L1","L2","L3","L4"] }
          },
          "validation_layer": {
            "type": "string",
            "enum": ["analytical","clinical_incremental","real_world"]
          }
        }
      }
    }
  }
}
```

### 2.5 Example Populated Registry (YAML Configuration)

The following YAML fragment is the populated registry shipped with the v1.0 baseline. It is committed under `/docs/backend-schema/registry.yaml` per the Vibe Coding folder structure and is consumed at build time by both the Codex backend generator and the Stage-Gate Governor service.

```yaml
registry_version: "1.0.0"
programme: "beAIve DengueSense"
classification: "Research Use Only"
components:
  - id: M1
    name: "Capture and Guidance"
    layer: L2
    function: "Positioning, lighting, motion, distance guidance"
    output: "Standardised video and metadata"
    release_condition: "Usability and repeatability pass"
    gate_state: "IN_DEVELOPMENT"
    owner_agent: "mixed"
    validation_layer: "analytical"
  - id: M2
    name: "Signal-Quality Engine"
    layer: L3
    function: "Detect unusable video before inference"
    output: "Quality score and reason code"
    release_condition: "Prespecified rejection-performance pass"
    gate_state: "IN_DEVELOPMENT"
    owner_agent: "codex"
    validation_layer: "analytical"
  - id: M3
    name: "rPPG Engine"
    layer: L4
    function: "Derive pulse waveform from facial colour changes"
    output: "HR, timing, morphology, perfusion features"
    release_condition: "Reference-device agreement pass"
    gate_state: "ANALYTICAL_VALIDITY"
    owner_agent: "codex"
    validation_layer: "analytical"
  - id: M4
    name: "Facial Perfusion"
    layer: L4
    function: "Regional colour and temporal perfusion analysis"
    output: "Forehead/cheek/nose features and asymmetry"
    release_condition: "Repeatability and bias review pass"
    gate_state: "ANALYTICAL_VALIDITY"
    owner_agent: "codex"
    validation_layer: "analytical"
  - id: M5
    name: "Ocular Research"
    layer: L4
    function: "Conjunctival region and temporal ocular features"
    output: "Colour, pallor/redness, vessel, blink features"
    release_condition: "Segmentation and reproducibility pass"
    gate_state: "IN_DEVELOPMENT"
    owner_agent: "claude"
    validation_layer: "analytical"
  - id: M6
    name: "Tongue/Oral Research"
    layer: L4
    function: "Standardised tongue-region segmentation (exploratory)"
    output: "Colour, coating, moisture/texture descriptors"
    release_condition: "Image-quality, annotation, repeatability, incremental-value gates pass"
    gate_state: "NOT_STARTED"
    owner_agent: "mixed"
    validation_layer: "analytical"
  - id: M7
    name: "Optical Haematology"
    layer: L4
    function: "Experimental RGB/NIR estimation"
    output: "Estimated Hb/Hct/platelet-related trends"
    release_condition: "Separate analytical-validation gate"
    gate_state: "NOT_STARTED"
    owner_agent: "codex"
    validation_layer: "analytical"
  - id: M8
    name: "Risk Engine"
    layer: L5
    function: "Fuse approved variables"
    output: "Probability, risk band, uncertainty"
    release_condition: "Locked external-validation pass"
    gate_state: "NOT_STARTED"
    owner_agent: "codex"
    modelling_levels: ["L1","L2","L3","L4"]
    validation_layer: "clinical_incremental"
  - id: M9
    name: "Research Dashboard"
    layer: L7
    function: "Present result and audit trail"
    output: "Clinician-readable research view"
    release_condition: "Human-factors review pass"
    gate_state: "IN_DEVELOPMENT"
    owner_agent: "claude"
    validation_layer: "real_world"
```

---

## 3. Data Flow & State Management

### 3.1 End-to-End Capture-Session Lifecycle

A single assessment session begins when a clinician or trained operator initiates a capture on a standardized smartphone or tablet and ends when the resulting record is archived in the audit trail. Between those two points, the system enforces a strict lifecycle designed to satisfy both clinical protocol (the 60–100 second standardized capture workflow) and statistical integrity (patient-level splits, training-only preprocessing, frozen external validation).

The seven-step standardized capture workflow, drawn directly from the DengueSense specification, dictates the on-device sequence:

1. **Identity and study-ID check** (≈5 sec) — study-ID only is entered in the capture interface; no direct identifiers are stored with the video.
2. **Positioning and lighting check** (5–10 sec) — distance, framing, exposure, and face visibility are verified.
3. **Neutral facial recording** (30–45 sec) — minimal movement, no talking; this is the primary input to the rPPG and Facial Perfusion modules.
4. **Ocular/conjunctival capture** (≈10 sec) — safe, non-contact positioning with segmentation confirmation.
5. **Dorsal tongue capture** (10–15 sec) — standardized lighting, colour control, focus, non-contact capture.
6. **Optional controlled task** (≈10 sec) — only if justified in the approved protocol.
7. **Quality result** (immediate) — accept, recapture with reason, or unable-to-acquire.

Once accepted, the recording is dispatched to the Signal-Quality Engine (M2), which enforces a hard gate: inference must be blocked when any critical quality rule fails. The rules assessed include face detection and region stability, motion and head-pose limits, exposure and lighting consistency (including glare and shadows), frame rate and compression artefacts, rPPG signal-to-noise ratio and spectral plausibility, occlusion from masks/glasses/hair over required regions, ocular segmentation confidence, tongue segmentation with focus and colour-reference verification, and required duration. Only on a positive quality result does feature extraction proceed.

### 3.2 Capture Session State Machine

The state machine below governs every session. Transitions are deterministic; agentic intervention is permitted only in the `QUALITY_CHECK` reflection step (to suggest recapture parameters) and the `REVIEW` step (to surface relevant prior scans). No agentic state transition may bypass the `RISK_OUTPUT` → `REVIEW` human checkpoint.

```
                ┌──────────┐
                │   INIT   │  ← operator opens capture app, study-ID entered
                └────┬─────┘
                     │ validate study-ID
                     ▼
              ┌──────────────┐
              │ POSITIONING  │  ← L2 Capture & Guidance: distance, framing, exposure
              └──────┬───────┘
                     │ all positioning checks green
                     ▼
              ┌──────────────┐
              │  CAPTURING   │  ← 60–100 sec, 7-step workflow
              └──────┬───────┘
                     │ recording complete
                     ▼
              ┌──────────────┐
              │ QUALITY_CHECK│  ← M2 Signal-Quality Engine + agentic reflection
              └──────┬───────┘
                     │
        ┌────────────┼────────────┐
        │ ACCEPT     │ RECAPTURE  │ FAILED
        ▼            ▼            ▼
   ┌─────────┐  ┌──────────┐  ┌────────┐
   │INFERENCE│  │ CAPTURING│  │ ARCHIVED│  (FAILED → unable to acquire)
   └────┬────┘  └──────────┘  └────────┘
        │ M3 rPPG · M4 Perfusion · M5 Ocular · M6 Tongue · M7 (if unlocked)
        ▼
   ┌─────────────┐
   │ RISK_OUTPUT │  ← M8 Risk Engine: probability + risk band + uncertainty
   └──────┬──────┘
          │ present to clinician via M9 Research Dashboard
          ▼
   ┌──────────┐
   │  REVIEW  │  ← clinician review, adjudication (no access to model output for label)
   └────┬─────┘
        │ signed off
        ▼
   ┌───────────┐
   │ ARCHIVED  │  ← audit trail, retention clock starts
   └───────────┘
```

### 3.3 Agentic Loop State Management

The agentic loop (Layer L6) maintains its own internal state machine, parallel to the capture-session state machine above. Four internal states govern how the AI agents (Codex and Claude) act on the system at development time and how the operational agentic services act on a session at runtime:

- **Planning state.** Given a task (e.g., "implement the rPPG engine wrapper for module M3"), the planning agent decomposes it against the six pre-code documents and the component registry. Output is a phased build plan with explicit dependencies and expected completion criteria.
- **Execution state.** Codex or Claude generates code (development) or runs a pipeline stage (operational). All actions are sandboxed; agentic-generated code must pass the Vibe Coding testing matrix (unit ≥80%, integration on all critical paths, E2E on all Must Have stories, security scans with zero high/critical) before merge.
- **Reflection state.** The agent evaluates its own output against the pre-code documents and the stage-gate acceptance criteria. Mismatches produce a structured reflection note, not an ad-hoc fix.
- **Error-correction state.** On failure, the agent performs smallest-cause root-cause analysis (per the Vibe Coding Debug and Fix prompt: "identify the smallest cause, patch it, do not refactor unrelated code"). Repeated failures escalate to a human owner in the RACI matrix; the agent may not silently retry beyond a configured threshold.

The diagram below shows how the four agentic states interact with the six Vibe Coding pre-code documents, the component registry, and the human review checkpoints. The loop is deliberately *reflective before corrective*: an agent must produce a structured reflection note before being permitted to enter error-correction, ensuring that systemic issues are surfaced to human owners rather than patched in isolation.

```
                         ┌─────────────────────────────────────┐
                         │  SIX PRE-CODE DOCUMENTS (source of  │
                         │  truth: PRD, TRD, App Flow, UI/UX    │
                         │  Brief, Backend Schema, Impl. Plan)  │
                         └──────────────────┬──────────────────┘
                                            │ read-only context
                                            ▼
   ┌─────────────────────┐         ┌───────────────┐         ┌────────────────────┐
   │  COMPONENT REGISTRY │ ──────▶ │   PLANNING    │ ──────▶ │     EXECUTION      │
   │  (M1..M9 versions,  │         │ decompose task│         │ Codex backend OR   │
   │   gate states,      │ ◀────── │ against docs  │ ◀────── │ Claude frontend    │
   │   owner agents)     │  plan   │ + registry    │  status │ generates code /   │
   └─────────────────────┘         └───────┬───────┘         │ runs pipeline stage│
                                           │                  └─────────┬──────────┘
                                           │ plan accepted                │ output produced
                                           │ (human-approvable)            ▼
                                           │                  ┌────────────────────┐
                                           │                  │     REFLECTION      │
                                           │                  │ evaluate vs docs +  │
                                           │                  │ gate criteria; write │
                                           │                  │ structured note      │
                                           │                  └─────────┬──────────┘
                                           │                            │
                                           │                  ┌─────────▼──────────┐
                                           │                  │  ERROR-CORRECTION  │
                                           │                  │ smallest-cause RCA │
                                           │                  │ patch + verify      │
                                           │                  └─────────┬──────────┘
                                           │                            │
                                           │   retries ≥ threshold?     │
                                           │             ┌───────────────┴────┐
                                           │             │ YES                │ NO
                                           │             ▼                    ▼
                                           │    ┌────────────────┐   ┌──────────────────┐
                                           │    │ HUMAN ESCALATE │   │  MERGE / DEPLOY  │
                                           │    │ (RACI owner)   │   │  + audit log     │
                                           │    └────────────────┘   └──────────────────┘
                                           │                                   │
                                           │                                   │
                                           └───── feedback ◀───────────────────┘
                                                 loop continues until
                                                 component gate_state advances
```

The loop is bounded: any task that requires more than a configured number of execution→reflection→error-correction cycles is escalated to the human RACI owner for the affected component. This bound is itself an architectural safeguard, ensuring that agentic non-determinism cannot silently consume indefinite engineering time or produce undocumented code paths.

### 3.4 Data Split, Leakage Control, and Statistical Integrity

A foundational design principle of the DengueSense programme — and therefore of this architecture — is that the model must never generate or influence its own label. The system enforces this through structural separation of data partitions and through pipeline rules that cannot be bypassed by agentic or human action:

- **Patient-level splits.** Data is split by participant, never by video or scan. Repeated scans from one participant remain in the same partition. Site and time structure are preserved where applicable.
- **Training-only preprocessing.** All preprocessing, imputation, feature selection, and calibration are fitted on training data only and applied (without re-fitting) to validation and test partitions.
- **Frozen external validation.** The external validation cohort is held at a separate site, used exactly once for the locked model, and never used for any tuning decision. Sample-size planning indicates ranges of 60–120 participants for engineering/feasibility, 400–800 for the development cohort, 150–300 for external validation, and a prospective silent-validation cohort.
- **Post-outcome variable exclusion.** Post-outcome variables and treatment decisions are prevented from entering pre-outcome models. A feature-availability timestamp is enforced at the feature-store layer.
- **Label independence.** Endpoints are adjudicated by a Clinical Endpoint Committee without access to model output. The composite primary endpoint — clinically meaningful deterioration within 24 hours after the index scan — is finalised before recruitment begins.

### 3.5 Stage-Gate State Transitions (G0 → G8)

The eighteen-month roadmap is organised into eight overlapping phases with nine stage gates. The Stage-Gate Governor service treats each gate as a system lifecycle state, with a defined decision evidence package and minimum criteria for progression. At any gate the decision options are: **proceed, proceed with conditions, repeat, narrow the intended use, pause, or stop**. Critical risks cannot be accepted solely by a technical owner, ensuring programme-level governance oversight.

| Gate | Phase | Core Outcome | Minimum Criteria for Progression |
|------|-------|---------------|----------------------------------|
| G0 | M0–M2: Mobilise and Define | Charter, intended use, endpoints, TPP, governance approved | All accountable owners approve the charter; unresolved critical assumptions logged |
| G1 | M2–M6: Capture and Signal Engineering | Capture app, SQI, rPPG, ocular/perfusion, tongue pipelines | ≥90% workflow completion in supervised usability testing; no open critical security issues |
| G2 | M4–M7: Analytical Validation | Reference-device agreement and repeatability evidence | Agreement limits and failure rate meet prespecified protocol targets across required subgroups |
| G3 | M1–M3 / M5–M9: Protocol and Feasibility | Clinical protocol, SAP, data dictionary, QMS, regulatory plan | Written ethics and regulatory approvals; site readiness confirmed |
| G4 | M5–M9: Feasibility Study | Workflow and data-quality evidence; event-rate estimate | Feasibility targets met; event rate sufficient to proceed to development |
| G5 | M7–M13: Multi-Site Model Development | Clinical baseline, multimodal model, frozen pipeline | Locked model and operating threshold; prespecified subgroup review complete |
| G6 | M11–M15: External Validation | Locked-site validation and subgroup review | Prespecified performance met on the untouched external cohort |
| G7 | M14–M18: Prospective Silent Validation | Real-time, non-interventional validation | Operational performance within prespecified bounds; false-alert rate acceptable |
| G8 | Post-M18: Closure / Transition | Decision on regulated clinical claim and commercial path | All regulatory, quality, and clinical-safety conditions satisfied for any claim change |

The architecture treats `G7` as the terminal research state; `G8` exists only to govern the transition out of Research Use Only classification. No code path may expose a risk output to a clinician outside the gated Research Dashboard view, and no model artifact may be promoted from `IN_DEVELOPMENT` to `LOCKED` without a corresponding gate transition recorded in the audit trail.

---

## 4. Architectural Decisions & Trade-offs

### 4.1 Technology Stack: Mapping Vibe Coding's Day One Stack to DengueSense

The Vibe Coding "Day One Stack" is opinionated by design: it prioritises developer velocity, ecosystem maturity, and production reliability over novelty. The combined architecture adopts this stack directly, with clinically-motivated adaptations. The default pick summary from Vibe Coding — Next.js on Vercel, Supabase for Postgres, Clerk for auth, Tailwind plus shadcn/ui for frontend, Codex for backend implementation, Claude for UI and product polish, PostHog plus Sentry once users exist, and Stripe once money exists — is preserved with the following domain mappings:

- **Codex (backend)** owns the implementation of M1 (Capture and Guidance server-side handlers), M2 (Signal-Quality Engine), M3 (rPPG Engine), M4 (Facial Perfusion), M7 (Optical Haematology), and M8 (Risk Engine). These are compute-heavy, schema-sensitive subsystems where Codex's ability to work inside the repository, read existing files, run checks, and iterate is most valuable.
- **Claude (frontend)** owns M5 (Ocular Research dashboard views for segmentation confirmation), M9 (Research Dashboard), and the operator-facing capture wizard. Claude is chosen for coherent UI with Tailwind, shadcn/ui, and consistent loading/empty/error/success states — qualities essential for clinician trust.
- **Supabase (Postgres)** is the persistence layer for the pseudonymised patient registry, scans, feature store, model registry, and audit logs. Row-level security policies enforce that clinicians see only their site's patients, researchers see only de-identified cohorts, and admins are fully audited.
- **Clerk (auth)** provides role-based access (clinician, researcher, biostatistician, programme director, admin) with multi-organisation support across study sites.
- **Vercel** hosts the Next.js dashboard and capture wizard; the heavier rPPG/perfusion/deep-learning inference workloads run on dedicated GPU-backed compute (out-of-scope of Vercel) and are accessed via typed API routes.
- **PostHog + Sentry** are enabled only after G3 (when feasibility data exists), per the Vibe Coding "Stop Overbuilding" rules: do not add product analytics, error tracking, or payments before the app has one working loop.
- **Stripe is explicitly excluded** from the research phase; the platform is not a commercial product until G8.

### 4.2 Why Contactless Camera-Based over Traditional Lab-Only Monitoring

Dengue can progress rapidly around the critical phase (typically days three to seven of illness), during which plasma leakage may lead to hypovolaemic shock, severe bleeding, or organ impairment. Current monitoring relies heavily on serial laboratory investigations — complete blood counts for haematocrit and platelet trends — which are resource-intensive, slow to repeat, and frequently unavailable in the very settings where dengue burden is highest. A low-cost, repeatable, contactless assessment that helps clinicians recognise deteriorating physiology earlier could fundamentally improve triage and monitoring workflows, particularly in resource-limited settings.

The architectural trade-off accepted here is **measurement uncertainty in exchange for accessibility and frequency**. The system does not claim to replace laboratory confirmation; it claims, at most and only after G6/G7, to provide a supplementary decision-support signal. The Signal-Quality Engine (M2) is therefore the most critical architectural component: it ensures that low-quality captures are blocked before inference, preventing the system from emitting a confident-looking but unjustified risk output. The "block inference" rule is non-negotiable and is enforced at the pipeline boundary, not as a soft warning.

### 4.3 Why Agentic Orchestration over Monolithic Development

A monolithic, human-only development approach would struggle to deliver the nine-module platform on an 18-month timeline while maintaining the documentation density required for regulatory submission (ISO 13485, IEC 62304, IEC 62366-1, ISO 14155, ISO 14971, IEC 81001-5-1, ISO/IEC 27001, and the FDA/IMDRF Software as a Medical Device risk categorisation). The Vibe Coding agentic methodology addresses this by treating the six pre-code documents as the *briefing a senior developer would receive on Day 1*, and by using Codex and Claude as force-multipliers that generate code, migrations, and UI within the constraints those documents define.

The trade-off accepted is **agentic non-determinism in exchange for velocity and documentation discipline**. Mitigations are structural: every AI-generated code change must be reviewed before merge; every agentic action is logged; the testing matrix (unit 80%+ coverage every commit, integration on all critical paths every PR, E2E on all Must Have stories every sprint, security scans with zero high/critical every sprint) is enforced in CI; and the Stage-Gate Governor prevents any module from being promoted without independent evidence review.

### 4.4 Architectural Decision Records (ADRs)

| ADR | Decision | Context | Consequences |
|-----|----------|---------|--------------|
| ADR-01 | Adopt Vibe Coding Day One Stack (Next.js, Vercel, Supabase, Clerk, Codex, Claude, Tailwind, shadcn/ui) | DengueSense requires both clinical-grade documentation density and 18-month delivery velocity; team is small and AI-augmented | Reduces infrastructure debate; constrains runtime to JavaScript/TypeScript ecosystem; GPU inference requires sidecar service outside Vercel |
| ADR-02 | Patient-level data splits; training-only preprocessing; frozen external validation | The model must never generate or influence its own label; leakage would invalidate the regulatory submission | Increases data collection cost; repeated scans cannot pad sample size; requires biostatistician sign-off on split before any modelling |
| ADR-03 | Hard signal-quality gate (M2) blocks inference on any critical rule failure | A confident-looking but unjustified risk output is more dangerous than no output | Some capture sessions will produce no result; recapture rate is a tracked operational metric and a reported performance dimension |
| ADR-04 | Risk Engine (M8) emits probability + risk band + uncertainty together; suppression of uncertainty is forbidden | Clinician over-reliance (R11) is a high-priority risk; uncertainty is the only defence against false confidence | Dashboard UX must always render three values; adds visual complexity; requires calibration evidence at gate |
| ADR-05 | Tongue/Oral (M6) and Optical Haematology (M7) are exploratory/experimental and gated separately | Reported oral manifestations are varied, non-specific, and may be treatment-related; optical haematology has not passed analytical validation | These modules cannot be combined into the Risk Engine until their own gates are passed; reduces near-term feature surface |
| ADR-06 | Agentic actions are logged and never permitted to mutate model artifacts, endpoint labels, or clinical records | Regulatory and clinical-safety frameworks require auditability and label independence | Adds latency to agentic loops; some refactoring tasks must be escalated to human owners; CI must verify audit completeness |
| ADR-07 | Stripe is excluded until G8; PostHog and Sentry are deferred until G3 | Vibe Coding "Stop Overbuilding" rules: do not add billing before commercial claim; do not add analytics before users exist | Reduces early-phase complexity; requires manual metric collection during engineering/feasibility phases |
| ADR-08 | Nine stage gates (G0–G8) with proceed / proceed-with-conditions / repeat / narrow / pause / stop options | Critical risks cannot be accepted solely by a technical owner; programme-level governance is required | Slows gate-to-gate progression; requires Executive Steering Committee and Clinical Steering Committee meetings at each gate |
| ADR-09 | Four-level modelling progression (descriptive → penalised LR → gradient boosting → multimodal DL); each level must outperform the prior on the locked evaluation set | Interpretability must precede complexity for regulatory acceptance and clinician trust | Higher engineering cost; Level 4 deep learning is only permitted after Levels 1–3 are documented and benchmarked |
| ADR-10 | Research Use Only classification until all ethics, clinical-research, quality-management, and regulatory conditions are satisfied | Premature commercial claims (R8) are a high-priority risk | Marketing and sales claims are governed by an approved-claims matrix; document control is enforced across all external communications |

### 4.5 Cross-Cutting Architectural Concerns

Three concerns cut across every layer and must be considered part of the architecture rather than bolted on after the fact:

- **Privacy and security baseline.** Only data required by the protocol is collected; direct identifiers are separated from research data; all information is encrypted in transit and at rest; role-based access with least privilege is enforced; consent, access, export, and deletion logs are maintained throughout the programme lifecycle; retention, archival, destruction, and cross-border-transfer rules are defined before recruitment begins.
- **Risk register and mitigation.** Fifteen identified risks span clinical, technical, regulatory, and operational domains. The register is reviewed fortnightly and at every stage gate. The most critical risks include insufficient deterioration events (R1, mitigated by event-count-based sample sizing with site-extension amendment option), poor signal quality in darker skin tones (R2, mitigated by subgroup-targeted signal-quality tuning), recruitment delay (R6, mitigated by prequalified backup sites), overclaiming by sales or partners (R8, mitigated by an approved-claims matrix), privacy or security incidents (R9, mitigated by pseudonymisation, least privilege, encryption, and rehearsed response plans), and clinician over-reliance (R11, mitigated by human-factors testing and clear limitation messaging).
- **Governance and decision rights.** Six bodies govern the programme: the Executive Steering Committee (monthly; budget, scope, partnerships, gate decisions, escalations), the Clinical Steering Committee (monthly and at each gate; intended use, endpoints, clinical safety, interpretation), the Technical Design Authority (fortnightly; architecture, interfaces, model pipeline, technical debt), a Data and Safety Monitoring body, plus the Clinical Endpoint Committee and the Regulatory/Quality function. A core RACI matrix defines accountability across the Executive Sponsor, Programme Director, Clinical Principal Investigator, and downstream owners.

---

## 5. Document Control

| Field | Value |
|-------|-------|
| Document ID | 01-system-architecture.md |
| Title | System Architecture & Core Design Specification |
| Version | 1.0 |
| Status | Baseline for System Design Review |
| Source documents | Vibe Coding v2.0 (June 2026); beAIve DengueSense v2.1 (August 2026) |
| Next documents in suite | 02-agentic-workflow.md, 03-data-specs.md, 04-api-reference.md, 05-devops-deployment.md, 06-security-compliance.md, master_prompt.md |
| Review cadence | Fortnightly (Technical Design Authority) and at each stage gate |

This document is the architectural foundation for the six-document technical suite. Subsequent documents elaborate the agentic workflow (02), data specifications and schema (03), API reference (04), DevOps and deployment (05), security and compliance (06), and the consolidated master prompt pack (master_prompt.md). Any change to the architecture described here must be reflected across the dependent documents and re-approved through the Technical Design Authority.
