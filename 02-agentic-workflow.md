# Agentic Workflow & Execution Framework

> **Document 02** of the beAIve DengueSense × Vibe Coding Technical Suite
> **Scope:** Implements the agentic design paradigm sourced from the Vibe Coding methodology (Dr. Abishek Murugan, v2.0, June 2026), adapted to the DengueSense clinical AI context (reAInmaker SDN BHD, v2.1, August 2026).
> **Audience:** Programme Director, Technical Design Authority, Clinical Principal Investigator, Engineering Leads, ML Engineers, Clinical Data Stewards.
> **Status:** Planning baseline — binding for all sprint execution and stage-gate reviews.

---

## Table of Contents

1. Methodology: The Agentic Design Paradigm
2. Autonomous Agent Loops
3. Tooling & Integrations
4. Sprint Execution in Clinical AI Context

---

## 1. Methodology: The Agentic Design Paradigm

### 1.1 The Vibe Coding Philosophy

The Vibe Coding methodology opens with a single, load-bearing premise:

> *"AI coding agents are powerful but not mind readers. The more context you give them upfront, the better and faster they build."*

AI coding agents — whether Codex, Claude, GPT-class models, or domain-specific clinical assistants — do not suffer from a lack of capacity. They suffer from a lack of context. Left to infer requirements, an agent will hallucinate stack choices, fabricate schema columns, invent API contracts, and produce UI that looks plausible but does not connect to anything. The Vibe Coding response is not to demand better agents but to feed them better briefs.

In the Vibe Coding model, every project begins with six pre-code documents that act as a senior-developer briefing on Day One: the Product Requirements Document (PRD), the Technical Requirements Document (TRD), the App Flow, the UI/UX Design Brief, the Backend Schema, and the Implementation Plan. Together they answer what is being built, how it works technically, how users move through it, how it looks, where data lives, and the exact order to build it. The ten minutes spent on these documents saves hours of fixing broken code, re-explaining context, and undoing bad architectural decisions. The result: fewer hallucinations, less back-and-forth, cleaner code.

### 1.2 How the Six Pre-Code Documents Eliminate Ambiguity

Each of the six documents closes a specific class of ambiguity that AI agents otherwise resolve by guessing.

The **PRD** eliminates *product* ambiguity. Without it, the agent does not know whether it is building a consumer app, an internal tool, or a regulated medical device. The PRD fixes the app name, tagline, problem statement, target user persona, must-have versus nice-to-have feature split, user stories, explicit out-of-scope section, and success metrics. For DengueSense, the equivalent artefact is the Programme Charter and Intended Use statement, which forbids the system from confirming or excluding dengue, replacing a complete blood count, diagnosing shock, directing treatment autonomously, or supporting unsupervised home use.

The **TRD** eliminates *technical* ambiguity. It locks the frontend framework, backend runtime, database provider, authentication method, hosting platform, third-party APIs, key libraries, environment variables, and hard constraints. Without a TRD, the AI picks a stack on its own — sometimes well, often inconsistently across files. For DengueSense the TRD must additionally pin clinical-grade choices: ISO 13485-aligned QMS, IEC 62304 software lifecycle, IEC 62366-1 usability engineering, ISO 14155 good clinical practice, ISO/IEC 27001 information-security controls, and the FDA/IMDRF Good Machine Learning Practice principles.

The **App Flow** eliminates *navigation* ambiguity. It defines every screen, navigation type, first screen, auth flow, the two-to-three most important core user journeys, empty/error/loading states, modals, and redirects. Without it, the AI builds pages in isolation; they work individually but never connect into one coherent product.

The **UI/UX Design Brief** eliminates *visual* ambiguity. AI agents default to plain, unstyled, or inconsistent UIs when left to their own judgment. The brief locks the aesthetic direction, color palette, typography, component style, dark/light preference, reference apps, key UI patterns, mobile responsiveness, and accessibility considerations.

The **Backend Schema** eliminates *data* ambiguity — the hardest document to change after the fact. The schema defines every table, column, primary key, foreign-key relationship, index, Row Level Security rule, user role, sensitive field, file storage path, webhook, and API endpoint. For DengueSense this maps to the Data Dictionary and the patient/scan/feature/outcome schema with patient-level split enforcement and predictor-availability timestamps.

The **Implementation Plan** eliminates *sequencing* ambiguity. It tells the agent what to build first, second, third, and why that order matters. Skipping it leads to the AI building the frontend before the backend exists or adding auth after the schema is half-baked. The plan is the checklist the agent ticks off, with clear phases, milestones, and completion criteria.

### 1.3 Mapping Agentic Methodology to DengueSense's Evidence-Driven Approach

The DengueSense programme is described in its charter as a *"disciplined, evidence-driven approach to developing an AI-powered clinical decision-support tool."* It follows a three-layer validation framework: analytical validity of camera-derived measurements first; then predictive value beyond routine clinical information; then a locked model tested in a separate real-world cohort without influencing care. The product remains Research Use Only until all ethics, clinical-research, quality-management, and medical-device requirements are satisfied.

This evidence-driven, stage-gated approach is the clinical expression of the agentic workflow, not a tension with it. Both rest on the same insight: agents perform better when given context, and context is enforced through artefacts that close ambiguity before code is written. The Vibe Coding six pre-code documents are the engineering analogue of DengueSense's nine stage gates (G0–G8) and four-level modelling progression. Just as the master prompt refuses to start coding before all six documents exist, the DengueSense governance refuses to enter a phase before its gate evidence is satisfied. Recruitment cannot begin before G3. The locked model cannot be evaluated on the untouched test set before G5. External validation cannot close before G6. The stage gate is the agentic brief for the next sprint.

### 1.4 The Stop Overbuilding Rules Applied to Clinical AI

Section 3.5 of the Vibe Coding document issues five Stop Overbuilding Rules. The clinical-AI equivalents, applied to DengueSense:

- **No patients enrolled yet, no complex model architecture.** Level-four temporal and multimodal deep learning is *"not a default milestone; it is an evidence-dependent option that requires sufficient data volume and diversity before deployment."* Ship the clinical-only baseline (Level 2) first.
- **No external validation yet, no clinical claim.** The approved-claims matrix gates what can be said publicly; overclaiming by sales or partners is risk R8, mitigated through document control.
- **If you cannot state the intended use in one sentence, the protocol will not save it.** The programme charter fixes the intended use: *"estimate the risk of clinically meaningful deterioration in eligible patients under healthcare-professional supervision,"* and explicitly forbids diagnosing dengue, replacing a CBC, diagnosing shock, or directing treatment.
- **If the data dictionary is unclear, do not start modelling.** Feature-availability timestamps must be maintained for every predictor; post-outcome variables and treatment decisions are prevented from entering pre-outcome models.
- **Ship the loop first.** The smallest working loop in DengueSense is the Capture → Signal-Quality → rPPG → Risk Band → Dashboard path. Optical Haematology, tongue incremental-value modelling, and deep-learning fusion are deferred until evidence supports them.

### 1.5 Comparison: Traditional, Agentic, and Clinical Agentic Workflows

| Dimension | Traditional Development | Agentic Workflow (Vibe Coding) | Clinical Agentic Workflow (DengueSense) |
|---|---|---|---|
| Primary driver | Human developer judgment | AI agent with structured context | AI agent with structured context + clinical governance |
| Pre-code artefacts | Ad-hoc or skipped | Six documents (PRD, TRD, App Flow, UI/UX, Schema, Plan) | Six documents + Clinical Protocol, SAP, Data Dictionary, Regulatory Plan, Risk Register, QMS |
| Decision authority | Lead developer | Lead developer + AI prompt review | Executive Steering Committee, Clinical Steering Committee, Technical Design Authority, DSMB, Endpoint Adjudication Committee, Privacy & Security Review |
| Build ordering | Feature-driven, often parallel | Phased: Setup → DB → Auth → Core features → Polish → Test → Deploy | Phased across 18 months: Mobilise → Protocol → Capture Engineering → Analytical Validation → Feasibility → Multi-Site Development → External Validation → Prospective Silent Validation → Regulatory Submission |
| Failure mode if context missing | Rework, scope creep | Hallucinated schema, broken flows | Hallucinated biomarker, unsafe clinical recommendation, regulatory rejection |
| Gate mechanism | Code review | Plan approval + sprint review | Nine stage gates G0–G8 with proceed / proceed-with-conditions / repeat / narrow / pause / stop |
| Error correction | Bug fixing | Debug prompt pack | Signal-Quality Gate + autonomous recapture instruction + acquisition-failure fallback |
| Ship criterion | Feature complete | "Ship the loop first" | Locked model + external validation + prespecified sensitivity/calibration/false-alert criteria met |
| Quality framework | Internal QA | Testing matrix (unit/integration/E2E/visual/perf/security) | ISO 13485, ISO 14971, IEC 62304, IEC 62366-1, ISO 14155, IEC 81001-5-1, ISO/IEC 27001, FDA/IMDRF GMLP, TRIPOD+AI, PROBAST+AI |
| Risk tolerance | Commercial | Commercial | Patient safety; critical risks cannot be accepted solely by a technical owner |

---

## 2. Autonomous Agent Loops

The agentic workflow is not a single prompt — it is a loop. Each iteration moves the programme forward by one bounded unit of work, then checks whether to continue, correct, or escalate. This section decomposes the loop into four phases — Planning, Execution, Self-Reflection, Error-Correction — and provides an ASCII diagram and a pseudo-code controller.

### 2.1 Planning Phase: From Master Prompt to Phased Implementation Plan

In Vibe Coding, the master prompt is the single instruction that begins every project. Its canonical form is:

> *"Think of yourself as a Full Stack Developer. Help me create a website step by step with action sprint phases… Analyze and understand the following project documents, then create an implementation plan in phases with all requirements, security measures, and good UI/UX considerations."*

The agent consumes the six pre-code documents and emits a nine-phase plan: Phase 1 Setup → Phase 2 Database → Phase 3 Auth → Phase 4 Core Feature 1 → Phase 5 Core Feature 2 → Phase 6 Core Feature 3 → Phase 7 UI Polish → Phase 8 Testing → Phase 9 Deploy. Each phase has a focus, key deliverables, and done criteria.

For DengueSense, the same prompt structure is run against a richer document set — the six pre-code documents plus the Programme Charter, Clinical Protocol, Statistical Analysis Plan, Data Dictionary, Regulatory Plan, Risk Register, and QMS — and produces an 18-month phased plan that maps cleanly onto the DengueSense roadmap:

| Vibe Coding Phase | DengueSense Programme Phase | Months | Exit Gate |
|---|---|---|---|
| Phase 1: Setup | Phase 0 — Mobilise and Define | M0–M2 | G0 |
| Phase 2: Database Schema | Phase 1 — Protocol and Foundation | M1–M3 | G1 / G3 prep |
| Phase 3: Auth | Phase 1 — Protocol and Foundation (RBAC for clinician/researcher/admin) | M1–M3 | G1 |
| Phase 4: Core Feature 1 | Phase 2 — Capture and Signal Engineering (Capture, SQI, rPPG, Facial Perfusion, Ocular, Tongue pipelines) | M2–M6 | G1 / T1–T3 |
| Phase 5: Core Feature 2 | Phase 3 — Analytical Validation (reference-device agreement, repeatability) | M4–M7 | G2 |
| Phase 6: Core Feature 3 | Phase 4 — Feasibility Study (workflow, data quality, event-rate estimate) | M5–M9 | G3 / G4 |
| Phase 7: UI Polish | Phase 5 — Multi-Site Model Development (clinical baseline, multimodal model, frozen pipeline) | M7–M13 | G5 |
| Phase 8: Testing | Phase 6 — External Validation (locked-site validation, subgroup review) | M11–M15 | G6 |
| Phase 9: Deploy | Phase 7 — Prospective Silent Validation | M14–M18 | G7 |
| (extension) | Phase 8 — Regulatory Submission | M18+ | G8 |

The plan is not approved until the Executive Steering Committee and the Clinical Steering Committee sign off — the Vibe Coding "Approved / Approved with Changes / Rejected" decision is replaced by the stage-gate decision set: *proceed, proceed with conditions, repeat, narrow the intended use, pause, or stop.*

### 2.2 Execution Phase: Sprint Execution Workflow

Once the plan is approved, the Vibe Coding sprint execution workflow applies directly. At the start of each sprint, tasks are selected from the implementation plan and loaded into the project management tool. During the sprint, the IDE agent generates code for each task using the prompt strategies from Section 8 of the Vibe Coding document. Every line of AI-generated code is reviewed for correctness, security vulnerabilities, and adherence to the design system. Code is never merged without review. Commits use descriptive messages referencing task IDs. The automated test suite runs after each commit. At the end of the sprint, deliverables are demonstrated to stakeholders and feedback is incorporated.

The clinical extension of this workflow adds three non-negotiable constraints. First, every commit that touches the model pipeline, the data dictionary, or the Risk Engine is tagged with the gate it supports (G0–G8) and the modelling level (1–4) it implements, so that auditors can reconstruct which code entered the evidence base for any gate decision. Second, patient-level splits are enforced at the data layer — repeated scans from one participant remain in the same partition, and a blinded test-set custodian is maintained where practical. Third, no commit that introduces a post-outcome variable, a treatment decision, or a feature without an availability timestamp may be merged; the CI pipeline rejects it.

### 2.3 Self-Reflection Phase: The 10-Step ML Analysis as an Agentic Loop

The DengueSense 10-step ML analysis sequence is, in agentic terms, the self-reflection loop of the model-building agent. Each step is a bounded reflection that produces evidence and only then permits the next step:

1. **Freeze** endpoint definitions, cohort rules, and data split — reflection produces a locked analytical scope.
2. **Validate** acquisition quality and reference-device agreement — reflection produces a quality attestation.
3. **Describe** missingness, exclusions, and cohort flow — reflection produces a CONSORT-style transparency artefact.
4. **Develop** a clinical-only baseline — reflection produces the benchmark any multimodal model must beat.
5. **Evaluate** candidate rPPG, perfusion, and ocular features using training data only — reflection produces a candidate-feature inventory.
6. **Compare** incremental value of each modality against the clinical-only baseline — reflection produces the inclusion/exclusion decision per feature.
7. **Select and lock** the final model and operating threshold — reflection produces the model card and threshold justification.
8. **Evaluate once** on the untouched internal test set — reflection produces a single, unrepeatable performance estimate.
9. **Validate** the locked pipeline at an external site — reflection produces generalisability evidence.
10. **Conduct prospective silent validation** using the locked model — reflection produces operational performance evidence.

The discipline of this loop — especially the "evaluate once" rule at step 8 — is the clinical equivalent of the Vibe Coding warning that *"the mistake is adding the serious startup stack before the app has one working loop."* Multiple peeks at the test set are the deep-learning equivalent of premature optimisation: each peek inflates the apparent performance and destroys the validity of the final estimate. The 10-step loop forbids it.

### 2.4 Error-Correction Phase: Signal-Quality Gate as Autonomous Correction

The Signal-Quality Engine is the agentic error-correction mechanism. It detects unusable video before inference, produces a quality score and reason code, and either accepts, requests recapture with an understandable reason, or records an acquisition failure rather than forcing a result. The engine assesses face detection and region stability; motion and head-pose limits; exposure and lighting consistency including glare and shadows; frame rate and compression artefacts; rPPG signal-to-noise ratio and spectral plausibility; occlusion from masks, glasses, or hair over required regions; ocular segmentation confidence; tongue segmentation with focus and colour-reference verification; and required duration with missing-frame detection. After the approved maximum attempts, the system records an acquisition failure rather than forcing a result — clinicians are never presented with output derived from inadequate input data.

This is the clinical analogue of the Vibe Coding Debug-and-Fix prompt: *"Inspect the relevant files, identify the smallest cause, patch it, and tell me exactly how to verify it. Do not refactor unrelated code."* The signal-quality gate inspects the relevant frames, identifies the smallest cause (motion, glare, occlusion, frame-rate drop), patches it (recapture instruction), and tells the operator exactly how to verify the fix. It does not refactor unrelated data, does not silently impute missing signals, and does not produce a fabricated risk score.

### 2.5 ASCII Diagram of the Full Agent Loop

```
                +--------------------------------+
                |     AGENT LOOP CONTROLLER      |
                +--------------------------------+
                                |
                                v
                +--------------------------------+
  OBSERVE  <--- |  Read gate evidence, worklog,  |
                |  backlog, data dictionary       |
                +--------------------------------+
                                |
                                v
                +--------------------------------+
  PLAN     <--- |  Apply Master Prompt; map phase |
                |  to stage gate; load prompt pack|
                +--------------------------------+
                                |
                                v
                +--------------------------------+
  ACT      <--- |  Generate code / run ML step /  |
                |  invoke capture pipeline         |
                +--------------------------------+
                                |
                                v
                +--------------------------------+
  VERIFY   <--- |  Run test suite; SQI gate;     |
                |  leakage audit; bias review     |
                +--------------------------------+
                                |
                                v
                +--------------------------------+
  REFLECT  <--- |  Compare to baseline; update   |
                |  model card; log evidence       |
                +--------------------------------+
                                |
                +---------------+---------------+
                |               |               |
                v               v               v
          +---------+     +-----------+   +-----------+
  CONTINUE|  next   |     |  CORRECT  |   | ESCALATE  |
          |  phase  |     |  recapture|   |  to gate   |
          +---------+     |  / retrain|   |  committee |
                          +-----------+   +-----------+

  Clinical guardrails (always on):
    - patient-level split enforced
    - post-outcome variables blocked at CI
    - critical risks cannot be accepted by technical owner alone
    - "evaluate once" on untouched test set
```

### 2.6 Pseudo-Code for the Agentic Loop Controller

```python
# denguesense_agent_loop.py
# Bounded controller for the DengueSense agentic workflow.
# Enforces stage-gate discipline, patient-level splits, and "evaluate once"
# semantics on the untouched test set.

GATES = ["G0","G1","G2","G3","G4","G5","G6","G7","G8"]
TEST_SET_PEEKS = 0  # must remain <= 1 across the programme

def agent_loop(programme_state):
    while not programme_state.terminal():
        gate = programme_state.current_gate()

        # 1. OBSERVE
        evidence = observe(
            gate_criteria=gate, worklog=programme_state.worklog,
            backlog=programme_state.sprint_backlog,
            data_dictionary=programme_state.data_dictionary,
            risk_register=programme_state.risk_register,
        )

        # 2. PLAN
        plan = master_prompt(
            documents=programme_state.pre_code_documents(),
            phase=programme_state.current_phase(), gate=gate,
        )

        # 3. ACT
        for task in plan.tasks:
            code = ide_agent.generate(task, prompt_pack=task.prompt_pack)
            if not human_review(code, role=task.review_role):
                continue  # CORRECT path
            enforce_patient_level_split(code)
            enforce_predictor_timestamps(code)
            commit(task.id, code, gate=gate, level=task.modelling_level)
            run_test_suite()

        # 4. VERIFY
        verdict = verify(
            gate=gate, evidence=evidence,
            sqi_passed=sqi_gate.all_passed(),
            leakage_audit_passed=leakage_audit.run(programme_state.data),
        )

        # 5. REFLECT
        if gate == "G5":
            reflect_model_lock(programme_state)
        if gate == "G6":
            global TEST_SET_PEEKS
            assert TEST_SET_PEEKS == 0, "Test set already consumed"
            evaluate_once_on_untouched_test_set(programme_state)
            TEST_SET_PEEKS += 1
        update_model_card(programme_state)

        # 6. CONTROL FLOW
        if verdict == "proceed":
            programme_state.advance_gate()
        elif verdict == "proceed_with_conditions":
            programme_state.log_conditions(verdict.conditions)
            programme_state.advance_gate()
        elif verdict == "repeat":
            continue
        elif verdict == "narrow":
            programme_state.narrow_intended_use()
        elif verdict == "pause":
            programme_state.await_decision("Executive Steering Committee")
        elif verdict == "stop":
            programme_state.terminate(reason=verdict.reason)
        else:
            escalate(verdict, to="Clinical Steering Committee")
```

The controller is deliberately conservative. It cannot merge code without human review. It cannot peek at the test set twice. It cannot accept a critical risk without escalating. It cannot advance a gate without its evidence. The agentic principle — *the more context you give them upfront, the better and faster they build* — is enforced by code, not by hope.

---

## 3. Tooling & Integrations

This section adapts the 10 ready-to-use Vibe Coding prompt packs to the DengueSense clinical context, defines when an agent may auto-act versus when a human-in-the-loop is required, and provides a tool registry.

### 3.1 The 10 Prompt Packs, Adapted for DengueSense

Each prompt pack below is the Vibe Coding original, rewritten to bind the agent to the clinical constraints (intended use, RBAC, signal-quality gate, patient-level splits, regulatory pathway).

**3.1.1 Master Prompt Template (clinical AI context)**

```
Think of yourself as a Full Stack Clinical AI Developer working on
beAIve DengueSense. Help me build the next programme phase step by
step with action sprint phases. Analyse and understand the following
project documents, then create an implementation plan mapped to the
relevant stage gate (G0–G8).

Attach or reference:
  - Programme Charter and Intended Use
  - Clinical Protocol and SAP
  - TRD (ISO 13485 / IEC 62304 / IEC 62366-1 / ISO 14155 aligned)
  - App Flow (Capture → SQI → rPPG → Risk Engine → Dashboard)
  - UI/UX Brief (clinician-readable, human-factors validated)
  - Backend Schema (patient-level splits, predictor-availability timestamps)
  - Regulatory Plan (MDA, NMRR/MREC, ISO/IEC 27001, FDA/IMDRF GMLP)
  - Risk Register (R1–R15) and QMS

Hard constraints:
  - Research Use Only; no clinical claim until G8.
  - Model must never generate or influence its own label.
  - Critical risks cannot be accepted by a technical owner alone.
```

**3.1.2 Backend Starter Prompt (Risk Engine, Clinical Data module)**

```
Read this repo first. I need the backend for the DengueSense Risk Engine:
  App: contactless, camera-based clinical decision-support for dengue
       risk stratification, Research Use Only.
  Users: clinician, researcher, admin, biostatistician (RBAC enforced)
  Core actions: ingest scan, run SQI gate, compute rPPG features,
                fuse with clinical data, emit risk band + uncertainty
  Data stored: patients, scans, features, outcomes, model_card, audit_log
  Auth: clinician sees own site; researcher sees de-identified;
        admin manages RBAC; biostatistician sees frozen splits
  Implement the smallest working backend. Clear schema names, validation,
  error handling, audit logging. Add setup notes and basic tests.
  Do not overbuild. No deep-learning fusion until G5 evidence supports it.
```

**3.1.3 Frontend Starter Prompt (Research Dashboard)**

```
Build the frontend for this DengueSense Research Dashboard screen:
  Screen: Patient Scan Result  |  User goal: clinician reviews risk band
  Data shown: risk probability, risk band, uncertainty, signal-quality score,
             feature contributions, audit trail
  Actions: view audit trail, request recapture, export to PDF (consented),
           escalate to clinician-in-charge
  Design direction: clinician-readable, high-contrast, no decorative gradients,
                    large typography for bedside readability, Tailwind + shadcn/ui
  States needed: Loading, Empty, Error, Acquisition-Failure, Success
  Accessibility: WCAG 2.1 AA, keyboard navigation, ARIA labels for risk bands
  Responsive: tablet-first (clinic context), desktop secondary, mobile read-only
```

**3.1.4 Database Schema Prompt (patient data, scans, features, outcomes)**

```
Design the schema for DengueSense:
  App: contactless dengue risk stratification | Research Use Only
  User roles: clinician, researcher, admin, biostatistician
  Core tables: patients, sites, devices, scans, sqi_results,
               rppg_features, perfusion_features, ocular_features,
               tongue_features, clinical_inputs, lab_values,
               outcomes, model_card, audit_log
  Important rules:
    - Patient-level split enforced; repeated scans stay in same partition
    - Predictor-availability timestamp on every feature
    - Post-outcome variables blocked at insert
    - Direct identifiers separated from research data
    - Row Level Security by site and role
  Return: 1. Tables and columns  2. Relationships  3. RLS plan
          4. Migration SQL  5. Seed data for local testing. Keep it simple.
```

**3.1.5 Auth Setup Prompt (RBAC for clinician/researcher/admin roles)**

```
Add RBAC to DengueSense. Requirements:
  - Roles: clinician, researcher, admin, biostatistician, dsmb_viewer
  - Clinicians see only their site's patients
  - Researchers see de-identified, consented cohorts only
  - Admins manage RBAC, sites, devices, retention policies
  - Biostatisticians see frozen splits; cannot see test set labels
  - DSMB viewer sees aggregated safety signals only
  - Protected routes require auth + role + site membership
  - Public routes: login, privacy policy, regulatory notices only
  - MFA required for admin and biostatistician roles
  - All access, consent, export, and deletion events logged
After implementation, tell me: 1. Required env vars  2. Where to add them
                                3. How to test each role
```

**3.1.6 Debug and Fix Prompt (model pipeline debugging)**

```
This DengueSense pipeline step is broken.
  Step: [e.g., rPPG feature extraction / SQI gate / Risk Engine inference]
  Expected: [e.g., HR within ±5 bpm of reference device]
  Actual:   [e.g., HR drifts >15 bpm after 30 s]
  Error:    [paste error or reason code]
Inspect the relevant files, identify the smallest cause, patch it,
and tell me exactly how to verify it. Do not refactor unrelated code.
Do not silently impute missing signals. Do not bypass the SQI gate.
If the cause is data quality, return a recapture instruction instead
of a forced result.
```

**3.1.7 UI Polish Prompt (clinical dashboard refinement)**

```
Review this DengueSense Dashboard screen like a senior clinical UX
designer and human-factors engineer. Fix:
  - spacing  - hierarchy  - tablet layout  - button clarity
  - empty / error / acquisition-failure states
  - text that wraps badly  - anything generic
  - risk-band colour contrast against WCAG 2.1 AA
  - bedside readability (lighting, distance, glare)
Keep the same clinical direction. Do not redesign the whole app.
Do not add visualisations not in the approved UI/UX brief.
Preserve the audit-trail affordance at all times.
```

**3.1.8 Launch Audit Prompt (pre-deployment clinical validation audit)**

```
Audit this DengueSense deployment before any prospective silent
validation or regulatory submission. Check:
  - build errors  - RBAC flow  - tablet layout  - first clinician flow
  - empty/error/acquisition-failure states
  - environment variables (no PHI in code)
  - database connection + patient-level split enforcement
  - SQI gate blocks inference on unusable video
  - model card published + threshold justification documented
  - leakage audit passed  - subgroup performance within tolerance
  - audit log captures every access, consent, export, deletion
  - MDA/NMRR/MREC approvals on file  - ISO/IEC 27001 controls in place
Return blockers first, then quick fixes. If any blocker is patient-safety
related, halt and escalate to Clinical Steering Committee.
```

**3.1.9 Build Plan Prompt (18-month roadmap build sequence)**

```
Here is the DengueSense programme snapshot: [paste snapshot]
Create the smallest build plan that gets this to a locked, externally
validated, prospectively silent-tested model. Map each workstream to a
stage gate (G0–G8) and a modelling level (1–4). Return:
  1. Programme phases (M0–M18+)  2. Database tables  3. RBAC rules
  4. API / model-pipeline actions  5. Components  6. Build order
  7. What to skip until evidence supports it
Be strict. Cut deep learning until event count justifies it.
Cut Optical Haematology until its separate analytical-validation gate
passes. Cut tongue incremental value until T6 gate passes.
```

**3.1.10 Vercel Deploy Prompt (or equivalent clinical hosting)**

```
Prepare DengueSense for deployment to the approved clinical hosting
environment (hospital data centre or sovereign cloud, NOT public Vercel,
unless Privacy & Security Review has approved Vercel for the research
dashboard layer only). Do the following:
  - Inspect package scripts  - Check build command
  - Check environment variables (secrets in vault, not in repo)
  - Check API routes / model-pipeline server functions
  - Check database config (bound to localhost, no public access)
  - Check that PHI is pseudonymised at the edge
  - Add a short deployment checklist signed by Regulatory + Privacy
Then run the local build if possible. If it fails, fix the smallest cause.
Do not deploy until the Launch Audit has returned zero blockers.
```

### 3.2 API Triggers and Autonomous Intervention Protocols

The DengueSense agent is not a free-running autonomous system. Its autonomy is bounded by a clinical-safety constraint: any action whose output could reach a clinician or influence a care decision requires human-in-the-loop review:

- **Auto-act (no human review required):** code generation for non-clinical modules (scaffolding, docs, test fixtures); running unit and integration tests; running the signal-quality gate on incoming video; computing de-identified feature vectors; producing audit-log entries; generating dashboards for retrospective research review.
- **Human-in-the-loop required (agent proposes, human dispositions):** any change to the data dictionary, the Risk Engine, the model card or threshold, RBAC rules, patient-level split logic, predictor-availability timestamps, any deployment to a clinical environment, any release of model output to a clinician-visible surface, any change to the regulatory evidence base.
- **Escalation required (cannot be auto-resolved):** any signal-quality failure after the approved maximum attempts; any leakage-audit failure; any subgroup performance below prespecified tolerance; any prospective-silent-validation alert rate exceeding the false-alert budget; any patient-safety signal raised by the DSMB.

The autonomy boundary is summarised in the tool registry below.

### 3.3 Tool Registry

| Tool | Purpose | Trigger | Autonomous? | Human Review Required? |
|---|---|---|---|---|
| IDE Agent (Codex / Claude / Cursor) | Generate code per prompt pack | Sprint task loaded | Yes — generates drafts | Yes — every line reviewed before merge |
| Master Prompt Orchestrator | Produce phased implementation plan | Programme start or new phase | Yes — proposes plan | Yes — Executive Steering Committee sign-off |
| Signal-Quality Engine | Block inference on unusable video | Every incoming scan | Yes — fully autonomous within rules | No — but reason codes logged for audit |
| Capture Guidance Module | Issue recapture instructions | SQI failure | Yes — within attempt budget | No — unless max attempts exceeded |
| rPPG / Perfusion / Ocular / Tongue Pipelines | Extract candidate biomarker features | Approved scan | Yes — feature extraction | Yes — feature inclusion at lock step |
| Risk Engine | Fuse approved variables, emit risk band | Locked model + approved inputs | Yes — inference | Yes — any change to engine or threshold |
| Biostatistics Pipeline (Python / R) | Run 10-step ML analysis | Phase 3–7 gate evidence request | Yes — runs analysis | Yes — biostatistician + Clinical PI sign-off |
| Leakage Auditor | Detect data leakage across splits | Pre-commit on data-touching code | Yes — runs in CI | Yes — any failure blocks merge |
| Model Card Generator | Produce model card + threshold justification | Model lock (G5) | Yes — drafts card | Yes — Clinical + Regulatory sign-off |
| Endpoint Adjudication System | Blinded confirmation of endpoints | Scheduled batches | Semi — batches are scheduled | Yes — Endpoint Adjudication Committee |
| DSMB Monitoring | Review safety signals and deviations | Per DSMB charter | No — human body | Yes — escalation to ESC |
| Launch Audit Prompt | Pre-deployment audit | Pre-G7 / pre-G8 | Yes — runs audit | Yes — blockers halt deployment |
| Audit Log Service | Capture access, consent, export, deletion | Every relevant event | Yes — always on | No — but periodically reviewed |
| Privacy & Security Review Tooling | Threat modelling, pentest, incident response | Pre-multi-site-deploy + quarterly | Semi — tooling autonomous | Yes — Privacy & Security Review body |

### 3.4 Tool Registry as JSON (machine-readable excerpt)

```json
{
  "tool_registry_version": "2.1",
  "programme": "beAIve DengueSense",
  "autonomy_policy": {
    "auto_act": [
      "code_drafting_non_clinical",
      "unit_integration_tests",
      "signal_quality_gate",
      "deidentified_feature_extraction",
      "audit_log_capture",
      "retrospective_research_dashboard"
    ],
    "human_in_loop_required": [
      "data_dictionary_change",
      "risk_engine_change",
      "model_card_or_threshold_change",
      "rbac_rule_change",
      "patient_level_split_logic_change",
      "predictor_availability_timestamp_change",
      "clinical_environment_deployment",
      "clinician_visible_release",
      "regulatory_evidence_change"
    ],
    "escalation_required": [
      "sqi_failure_after_max_attempts",
      "leakage_audit_failure",
      "subgroup_performance_below_tolerance",
      "false_alert_budget_exceeded",
      "dsmb_patient_safety_signal"
    ]
  },
  "tools": [
    {"name": "IDE Agent",            "trigger": "sprint_task_loaded",     "autonomous": true,  "human_review": "every line before merge"},
    {"name": "Signal-Quality Engine", "trigger": "incoming_scan",         "autonomous": true,  "human_review": "reason codes logged for audit"},
    {"name": "Risk Engine",          "trigger": "locked_model_approved_inputs", "autonomous": true, "human_review": "any change to engine or threshold"},
    {"name": "Biostatistics Pipeline","trigger": "gate_evidence_request", "autonomous": true,  "human_review": "biostatistician + Clinical PI sign-off"},
    {"name": "Launch Audit Prompt",  "trigger": "pre_G7_or_pre_G8",       "autonomous": true,  "human_review": "blockers halt deployment"}
  ]
}
```

---

## 4. Sprint Execution in Clinical AI Context

### 4.1 Sprints Map to Stage Gates (G0–G8)

The Vibe Coding sprint cadence — select tasks, generate, review, commit, test, demo — is preserved, but the demo is replaced by a stage-gate review. A sprint does not close when its tasks are complete; it closes when its gate's evidence is satisfied and the gate committee has rendered a decision. The nine gates and the sprint evidence required at each:

| Gate | Phase | Sprint Evidence | Decision Authority |
|---|---|---|---|
| G0 | Mobilise and Define | Charter, intended use, endpoints, TPP, governance approved; unresolved critical assumptions logged | Executive Steering Committee |
| G1 | Capture & Signal Engineering | ≥90% workflow completion in supervised usability testing; no open critical security issues | Clinical Steering Committee + Technical Design Authority |
| G2 | Analytical Validation | Agreement limits and failure rate meet prespecified protocol targets across required subgroups | Clinical Steering Committee |
| G3 | Protocol and Foundation | Written ethics and regulatory approvals (NMRR/MREC, MDA); site initiation complete | Regulatory and Quality leads + Clinical PI |
| G4 | Feasibility Study | Recruitment and usable-signal rates within approved tolerance; event-rate estimate | Executive Steering Committee |
| G5 | Multi-Site Model Development | Clinical baseline with leakage audit passed; model card and threshold approved | Clinical Steering Committee + Biostatistician + TDA |
| G6 | External Validation | Prespecified sensitivity, calibration, and false-alert criteria met; acceptable subgroup uncertainty at independent site | Clinical Steering Committee + Biostatistician |
| G7 | Prospective Silent Validation | Real-time performance consistent with validation; human-factors review passed | Clinical Steering Committee + Human Factors |
| G8 | Regulatory Submission | MDA pathway confirmation; submission-grade evidence plan approved | Executive Steering Committee + Regulatory |

At any gate, the decision is one of: *proceed, proceed with conditions, repeat, narrow the intended use, pause, or stop.* Critical risks cannot be accepted solely by a technical owner — the clinical analogue of the Vibe Coding rule that *"never merge AI-generated code without review."*

### 4.2 The Build Sequence, Applied to DengueSense

Section 14 of the Vibe Coding document prescribes the exact build order: write the one-sentence promise, list user roles, define schema, add auth, build one core flow, deploy preview, test on mobile, add payment after core flow works, add analytics, add error tracking. The DengueSense adaptation preserves the order and substitutes clinical equivalents for the commercial steps.

```
+------------------------------------------------------------------+
|              SPRINT-TO-GATE MAPPING (DENGUESENSE)                 |
+------------------------------------------------------------------+
| Vibe Coding step        | DengueSense adaptation      | Gate     |
+-------------------------+-----------------------------+----------+
| 1. One-sentence promise | Intended-use statement      | G0       |
| 2. List user roles      | RBAC roles: clinician,      | G0       |
|                         | researcher, admin,          |          |
|                         | biostatistician, DSMB       |          |
| 3. Define schema        | Data dictionary +           | G1 prep  |
|                         | patient-level splits +      |          |
|                         | predictor timestamps       |          |
| 4. Add auth             | RBAC + MFA + audit log      | G1       |
| 5. Build one core flow  | Capture -> SQI -> rPPG ->   | G1/G2    |
|                         | Risk Band -> Dashboard      |          |
| 6. Deploy preview       | Research environment only;  | G3       |
|                         | no clinician-visible surf.  |          |
| 7. Test on mobile/      | Tablet-first usability;     | G1/G7    |
|    tablet               | human-factors review         |          |
| 8. Add payment ->       | Regulatory submission       | G8       |
|    N/A, replace with    | (MDA, NMRR/MREC, ISO/IEC,   |          |
|    regulatory submission| FDA/IMDRF GMLP)              |          |
| 9. Add analytics        | Performance reporting:       | G6/G7    |
|                         | AUROC, AUPRC, calibration,  |          |
|                         | false-alert rate, lead time |          |
| 10. Add error tracking  | Audit log + Sentry-class     | All      |
|                         | error tracking + DSMB        |          |
|                         | monitoring                   |          |
+-------------------------+-----------------------------+----------+
```

The substitutions matter. "Add payment after core flow works" becomes "add regulatory submission after the model is locked and externally validated" — the discipline is identical: do not pursue the commercial/regulatory step until the working loop is proven. "Add analytics" becomes "add performance reporting aligned to TRIPOD+AI and PROBAST+AI." "Add error tracking" becomes the audit-log + DSMB + Sentry stack that every clinical deployment requires.

### 4.3 Sprint Cadence and Review Checkpoints

Sprints run on a two-week cadence, aligned to the Technical Design Authority's fortnightly cycle. Each sprint opens with a backlog-loading session (select tasks, map each to a gate and modelling level, confirm the prompt pack), executes through the IDE agent with continuous human review, and closes with three checkpoints: a code-review checkpoint (every line of AI-generated code reviewed before merge), a test-suite checkpoint (unit, integration, SQI and leakage-audit gates green), and a stage-gate-evidence checkpoint (does the sprint produce or advance evidence toward the next gate?).

Monthly checkpoints layer on top: the Executive Steering Committee and Clinical Steering Committee meet monthly and at each gate; the Privacy and Security Review body meets monthly during the build phase and quarterly thereafter. The Endpoint Adjudication Committee processes scheduled batches of blinded endpoint confirmations. The DSMB operates per its charter. The RAID log (Risk, Assumptions, Issues, Dependencies) is reviewed fortnightly and at every stage gate — the direct mapping of the Vibe Coding "commit with descriptive messages referencing task IDs" discipline into programme-level risk management.

### 4.4 The "Ship the Loop First" Discipline in Clinical Context

The Vibe Coding maxim — *"the mistake is adding the serious startup stack before the app has one working loop. Ship the loop first"* — has a clinical restatement: *the mistake is adding deep learning, multimodal fusion, and optical haematology before the clinical-only baseline loop is proven.* The 10-step ML analysis sequence enforces this: step 4 develops a clinical-only baseline before any camera-derived feature is evaluated; step 6 compares incremental value against that baseline; step 7 locks the model only if incremental value is demonstrated. The four-level modelling progression reinforces it: Level 1 descriptive statistics; Level 2 penalised logistic regression and interpretable baselines; Level 3 tree-based models; Level 4 temporal and multimodal deep learning — used only when event count and data diversity justify the additional complexity. Sprints in Phases 2–3 build the loop (Capture → SQI → rPPG → Dashboard). Sprints in Phase 5 extend the loop with the clinical baseline first, candidate features second, incremental value third, and locked model fourth. Sprints in Phases 6–7 do not add complexity; they test whether the locked loop generalises. Deep learning is not a sprint goal in itself — it is an evidence-gated outcome of Phase 5, only if the event count and data diversity thresholds are met.

### 4.5 Closing the Loop Between Agentic Speed and Clinical Caution

The agentic workflow's value proposition is velocity: better context upstream yields faster, cleaner code downstream. The clinical context's value proposition is safety: every claim must survive independent, prespecified, locked validation. These are not in conflict. The Vibe Coding document argues that *"the ten minutes you spend on these documents saves hours of fixing broken code."* The DengueSense equivalent is that the weeks spent on the Programme Charter, Clinical Protocol, SAP, Data Dictionary, and Regulatory Plan save months of rework, failed gates, and regulatory rejection. The agentic loop controller in Section 2.6 is the binding contract: it cannot merge code without review, cannot peek at the test set twice, cannot accept a critical risk without escalation, and cannot advance a gate without evidence. It is the operational expression of the methodology — *the more context you give them upfront, the better and faster they build — and in clinical AI, the safer they build too.*

---

*End of Document 02 — Agentic Workflow & Execution Framework.*
