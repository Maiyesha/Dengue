# Data Engineering & Model Specifications

> **Document 03 of 7** — beAIve DengueSense × Vibe Coding Technical Suite
> **Scope:** This document specifies the data schemas, preprocessing pipelines, and evaluation metrics that govern the beAIve DengueSense multimodal risk-assessment pipeline. It is the authoritative technical reference for data engineers, ML scientists, validation leads, and regulatory reviewers.
> **Status:** Research Use Only — Planning Baseline. All schemas are versioned (`schema_version`) and any breaking change requires Biostatistician and Regulatory sign-off under stage gates G0–G8.

---

## 1. Data Schemas: Input Variables, Features, and Target Outputs

The beAIve DengueSense system draws candidate inputs from multiple physiological domains: facial regions, remote photoplethysmography (rPPG), ocular features, tongue/oral features, clinical observations, laboratory values, and contextual metadata. Per Section 4.2 of the DengueSense Technical Documentation, **candidate features do not become production inputs merely because they correlate in exploratory analysis**; they must survive prespecified validation, redundancy review, leakage review, subgroup evaluation, and clinical interpretation before inclusion in the final locked model. Every field defined below carries a `feature_availability_timestamp` to enforce leakage controls (Section 7.2).

### 1.1 Domain Overview

Schemas are grouped into seven feature domains plus a target-output domain:

| # | Domain | Source Module | Output Type | Locked at Gate |
|---|--------|---------------|-------------|----------------|
| D1 | Facial region features | Facial Perfusion module | Regional intensity, temporal variation, asymmetry, perfusion trend, recovery dynamics | G5 |
| D2 | rPPG features | rPPG Engine | HR, IBI, HRV, pulse amplitude, AC/DC ratio, waveform morphology, signal quality | G2 (analytical) |
| D3 | Ocular features | Ocular Research module | Conjunctival colour, pallor/redness, vessel visibility, blink rate, segmentation confidence | G5 |
| D4 | Tongue/oral features | Tongue/Oral Research module | Tongue-body colour, coating, moisture, texture, fissures, papillary appearance, visible lesions | T1–T6 |
| D5 | Clinical inputs | Clinical Data module | Age, sex, day of illness, vitals, symptoms, warning signs | G3 |
| D6 | Laboratory values | Clinical Data module + optional Optical Haematology | Hb, Hct, WBC, platelets with timestamps and methodology | G2 |
| D7 | Contextual metadata | Capture and Guidance module | Camera model, FPS, resolution, exposure, distance, angle, lighting, site, operator, ambient | G1 |
| D8 | Target outputs | Risk Engine | Risk probability, risk band, uncertainty, lead-time estimate | G5/G6/G7 |

### 1.2 Facial Region Features (D1)

The Facial Perfusion module produces spatially resolved descriptors over five anatomical regions: **forehead**, **left cheek**, **right cheek**, **nose**, **periorbital**. Each region carries five feature classes: `regional_intensity` (CIELAB L\*a\*b\*), `temporal_variation` (low-frequency oscillations consistent with vasomotor activity), `asymmetry` (left/right homologous-region comparison), `perfusion_trend` (slope of intensity change across the 30–45 s neutral recording), and `recovery_dynamics` (post-stimulus return to baseline following the optional controlled task).

### 1.3 rPPG Features (D2)

The rPPG Engine derives pulse waveforms from subtle facial colour changes. Seven feature groups: `heart_rate` (bpm, with 95% CI from spectral peak width), `inter_beat_interval` (ms), `heart_rate_variability` (SDNN, RMSSD; LF, HF, LF/HF), `pulse_amplitude` (calibrated), `ac_dc_ratio` (pulsatility perfusion index), `waveform_morphology` (systolic peak, dicrotic notch, augmentation index, rise time), and `signal_quality_indicators` (SNR, spectral plausibility, motion artefact index). All rPPG features require a prespecified reference-device agreement pass at G2.

### 1.4 Ocular Features (D3)

Descriptors from the conjunctival and temporal ocular region: `conjunctival_colour` (CIELAB L\*a\*b\* + derived redness index), `pallor_descriptor` and `redness_descriptor` (ordinal mapped from continuous chrominance), `vessel_visibility` (scleral-vessel contrast score), `blink_rate` (events/min, from eyelid landmarks), `segmentation_confidence` (mean IoU of conjunctival mask). Both segmentation and reproducibility gates must pass.

### 1.5 Tongue/Oral Features (D4)

The Tongue/Oral Research module captures descriptors from a single core dorsal tongue view; optional lateral/ventral views require a separate SOP when the research question explicitly includes visible lesions or bleeding. Features: `tongue_body_colour_distribution` (CIELAB histogram + dominant centroids), `coating_colour`, `coating_coverage` (%), `coating_thickness` (0–3), `surface_moisture_gloss` (specular-highlight ratio), `texture` (GLCM contrast, homogeneity, entropy), `fissures` (count, depth, orientation), `papillary_appearance` (enum), and `visible_lesions` (ulceration, petechiae, bleeding, haematoma — each with location, size, confidence). **Exploratory** module subject to the six-gate evidence framework T1–T6: capture quality, segmentation performance, annotation reliability, repeatability, clinical association, incremental value.

### 1.6 Clinical Inputs (D5)

`age` (years), `sex`, `day_of_illness` (integer), `temperature` (°C), `systolic_bp`/`diastolic_bp` (mmHg), `pulse_pressure` (derived), `respiratory_rate`, `spo2` (%), `capillary_refill_time` (s), `symptoms` (codes: headache, retro-orbital pain, myalgia, arthralgia, nausea, vomiting, rash, abdominal pain), and `warning_signs` (WHO 2009: abdominal pain/tenderness, persistent vomiting, clinical fluid accumulation, mucosal bleed, lethargy/restlessness, hepatomegaly >2 cm, concurrent haemoconcentration with rapid platelet fall).

### 1.7 Laboratory Values (D6)

Stored with mandatory `timestamp`, `methodology`, and `specimen_type`: `haemoglobin` (g/dL), `haematocrit` (%), `wbc_count` (×10⁹/L), `platelet_count` (×10⁹/L). The optional Optical Haematology module produces experimental RGB/NIR-derived estimates stored under a separate `optical_estimates` sub-document, flagged experimental and subject to a separate analytical-validation gate.

### 1.8 Contextual Metadata (D7)

Captured automatically by Capture and Guidance: `camera_model`, `frame_rate` (Hz), `resolution`, `exposure` (EV), `distance` (cm), `angle` (deg, head pose), `lighting_conditions` (lux, colour temperature K), `site` (anonymised), `operator_id` (hashed), `ambient_conditions` (temperature, humidity where feasible). Used for subgroup analysis (§3.7) and confounder detection in the leakage audit (§7.2).

### 1.9 Target Output Schema (D8)

The Risk Engine fuses approved variables into a `RiskAssessment` payload: `risk_probability` (0.0–1.0), `risk_band` (Low / Moderate / High / Uncertain), `uncertainty` (epistemic and aleatoric estimates, 95% credible interval), `lead_time_estimate` (predicted hours before clinical endpoint, 95% CI), and `operating_threshold_version` (locked threshold identifier). The Uncertain band is returned when signal quality is borderline or the uncertainty interval straddles the high-risk threshold.

### 1.10 JSON Schema — ScanSession

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://denguesense.reainmaker.ai/schema/ScanSession/v1.2.0",
  "title": "ScanSession",
  "type": "object",
  "required": ["session_id", "participant_id", "site_code", "captured_at", "operator_id_hash", "schema_version", "quality_decision", "capture_steps"],
  "properties": {
    "session_id": { "type": "string", "format": "uuid" },
    "participant_id": { "type": "string", "pattern": "^[A-F0-9]{16}$", "description": "Pseudonymised participant identifier; direct identifiers held separately." },
    "site_code": { "type": "string", "enum": ["SITE-A", "SITE-B", "SITE-C", "SITE-D", "SITE-EXT"] },
    "captured_at": { "type": "string", "format": "date-time" },
    "operator_id_hash": { "type": "string", "pattern": "^[a-f0-9]{64}$" },
    "schema_version": { "type": "string", "pattern": "^v1\\.[0-9]+\\.[0-9]+$" },
    "duration_sec": { "type": "number", "minimum": 60, "maximum": 100 },
    "quality_decision": {
      "type": "object",
      "required": ["status", "score", "reason_codes"],
      "properties": {
        "status": { "enum": ["ACCEPT", "RECAPTURE", "UNABLE_TO_ACQUIRE"] },
        "score": { "type": "number", "minimum": 0, "maximum": 1 },
        "reason_codes": { "type": "array", "items": { "type": "string" } }
      }
    },
    "capture_steps": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["step_name", "duration_sec", "artefact_uri"],
        "properties": {
          "step_name": { "enum": ["identity_check", "positioning", "neutral_face", "ocular_capture", "dorsal_tongue", "controlled_task", "quality_result"] },
          "duration_sec": { "type": "number", "minimum": 0 },
          "artefact_uri": { "type": "string", "format": "uri" },
          "passed_quality_checks": { "type": "array", "items": { "type": "string" } }
        }
      },
      "minItems": 6,
      "maxItems": 7
    },
    "metadata": { "$ref": "#/$defs/ContextualMetadata" }
  },
  "$defs": {
    "ContextualMetadata": {
      "type": "object",
      "required": ["camera_model", "frame_rate", "resolution", "exposure", "distance_cm", "angle_deg", "lighting_lux", "ambient_temp_c", "ambient_humidity_pct"],
      "properties": {
        "camera_model": { "type": "string" },
        "frame_rate": { "type": "number", "minimum": 20, "maximum": 240 },
        "resolution": { "type": "string", "pattern": "^[0-9]+x[0-9]+$" },
        "exposure": { "type": "number" },
        "distance_cm": { "type": "number", "minimum": 20, "maximum": 80 },
        "angle_deg": { "type": "number", "minimum": -15, "maximum": 15 },
        "lighting_lux": { "type": "number", "minimum": 200 },
        "ambient_temp_c": { "type": "number" },
        "ambient_humidity_pct": { "type": "number", "minimum": 0, "maximum": 100 }
      }
    }
  }
}
```

### 1.11 JSON Schema — FeatureVector

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://denguesense.reainmaker.ai/schema/FeatureVector/v1.2.0",
  "title": "FeatureVector",
  "type": "object",
  "required": ["session_id", "schema_version", "extracted_at", "facial_regions", "rppg", "ocular", "tongue_oral", "clinical", "laboratory", "feature_availability_timestamps"],
  "properties": {
    "session_id": { "type": "string", "format": "uuid" },
    "schema_version": { "type": "string" },
    "extracted_at": { "type": "string", "format": "date-time" },
    "pipeline_version": { "type": "string" },
    "facial_regions": {
      "type": "object",
      "properties": {
        "forehead":     { "$ref": "#/$defs/RegionFeatures" },
        "left_cheek":   { "$ref": "#/$defs/RegionFeatures" },
        "right_cheek":  { "$ref": "#/$defs/RegionFeatures" },
        "nose":         { "$ref": "#/$defs/RegionFeatures" },
        "periorbital":  { "$ref": "#/$defs/RegionFeatures" }
      }
    },
    "rppg": {
      "type": "object",
      "required": ["heart_rate", "inter_beat_interval", "ac_dc_ratio", "signal_quality"],
      "properties": {
        "heart_rate": { "type": "number", "minimum": 30, "maximum": 220 },
        "heart_rate_ci95": { "type": "array", "items": { "type": "number" }, "minItems": 2, "maxItems": 2 },
        "inter_beat_interval": { "type": "number", "minimum": 200, "maximum": 2000 },
        "hrv": { "type": "object", "properties": { "sdnn": { "type": "number" }, "rmssd": { "type": "number" }, "lf_hf_ratio": { "type": "number" } } },
        "pulse_amplitude": { "type": "number" },
        "ac_dc_ratio": { "type": "number", "minimum": 0 },
        "waveform_morphology": { "type": "object", "properties": { "augmentation_index": { "type": "number" }, "rise_time_ms": { "type": "number" }, "dicrotic_notch_visible": { "type": "boolean" } } },
        "signal_quality": { "type": "object", "required": ["snr_db", "spectral_plausibility"], "properties": { "snr_db": { "type": "number" }, "spectral_plausibility": { "type": "number", "minimum": 0, "maximum": 1 }, "motion_artefact_index": { "type": "number" } } }
      }
    },
    "ocular": {
      "type": "object",
      "properties": {
        "conjunctival_colour_lab": { "type": "array", "items": { "type": "number" }, "minItems": 3, "maxItems": 3 },
        "pallor_descriptor": { "type": "integer", "minimum": 0, "maximum": 4 },
        "redness_descriptor": { "type": "integer", "minimum": 0, "maximum": 4 },
        "vessel_visibility": { "type": "number", "minimum": 0, "maximum": 1 },
        "blink_rate_per_min": { "type": "number", "minimum": 0 },
        "segmentation_confidence": { "type": "number", "minimum": 0, "maximum": 1 }
      }
    },
    "tongue_oral": {
      "type": "object",
      "properties": {
        "body_colour_distribution": { "type": "object" },
        "coating_colour_lab": { "type": "array", "items": { "type": "number" }, "minItems": 3, "maxItems": 3 },
        "coating_coverage_pct": { "type": "number", "minimum": 0, "maximum": 100 },
        "coating_thickness": { "type": "integer", "minimum": 0, "maximum": 3 },
        "surface_moisture_gloss": { "type": "number" },
        "texture": { "type": "object", "properties": { "contrast": { "type": "number" }, "homogeneity": { "type": "number" }, "entropy": { "type": "number" } } },
        "fissures": { "type": "array", "items": { "type": "object", "properties": { "count": { "type": "integer" }, "depth": { "type": "integer", "minimum": 0, "maximum": 3 }, "orientation": { "type": "string" } } } },
        "papillary_appearance": { "type": "string" },
        "visible_lesions": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["lesion_type", "location", "confidence"],
            "properties": {
              "lesion_type": { "enum": ["ulceration", "petechiae", "bleeding", "haematoma"] },
              "location": { "type": "string" },
              "size_mm": { "type": "number" },
              "confidence": { "type": "number", "minimum": 0, "maximum": 1 }
            }
          }
        }
      }
    },
    "clinical": {
      "type": "object",
      "properties": {
        "age": { "type": "integer", "minimum": 1, "maximum": 120 },
        "sex": { "enum": ["female", "male", "intersex", "not_stated"] },
        "day_of_illness": { "type": "integer", "minimum": 1, "maximum": 14 },
        "temperature_c": { "type": "number" },
        "systolic_bp": { "type": "integer" },
        "diastolic_bp": { "type": "integer" },
        "pulse_pressure": { "type": "integer" },
        "respiratory_rate": { "type": "integer" },
        "spo2_pct": { "type": "number", "minimum": 50, "maximum": 100 },
        "capillary_refill_time_sec": { "type": "number" },
        "symptoms": { "type": "array", "items": { "type": "string" } },
        "warning_signs": { "type": "array", "items": { "enum": ["abdominal_pain", "persistent_vomiting", "fluid_accumulation", "mucosal_bleed", "lethargy", "hepatomegaly", "haemoconcentration_rapid_platelet_fall"] } }
      }
    },
    "laboratory": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["test_name", "value", "unit", "timestamp", "methodology"],
        "properties": {
          "test_name": { "enum": ["haemoglobin", "haematocrit", "wbc_count", "platelet_count"] },
          "value": { "type": "number" },
          "unit": { "type": "string" },
          "timestamp": { "type": "string", "format": "date-time" },
          "methodology": { "type": "string" },
          "specimen_type": { "type": "string" }
        }
      }
    },
    "feature_availability_timestamps": {
      "type": "object",
      "description": "Per-predictor availability timestamp; used to enforce pre-outcome-only inputs (Section 7.2).",
      "additionalProperties": { "type": "string", "format": "date-time" }
    }
  },
  "$defs": {
    "RegionFeatures": {
      "type": "object",
      "required": ["regional_intensity", "temporal_variation", "asymmetry", "perfusion_trend", "recovery_dynamics"],
      "properties": {
        "regional_intensity": { "type": "array", "items": { "type": "number" }, "minItems": 3, "maxItems": 3, "description": "CIELAB L*a*b*" },
        "temporal_variation": { "type": "number" },
        "asymmetry": { "type": "number" },
        "perfusion_trend": { "type": "number" },
        "recovery_dynamics": { "type": "number" }
      }
    }
  }
}
```

### 1.12 JSON Schema — RiskAssessment

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://denguesense.reainmaker.ai/schema/RiskAssessment/v1.2.0",
  "title": "RiskAssessment",
  "type": "object",
  "required": ["assessment_id", "session_id", "schema_version", "generated_at", "risk_probability", "risk_band", "uncertainty", "lead_time_estimate", "operating_threshold_version", "model_card_uri"],
  "properties": {
    "assessment_id": { "type": "string", "format": "uuid" },
    "session_id": { "type": "string", "format": "uuid" },
    "schema_version": { "type": "string" },
    "generated_at": { "type": "string", "format": "date-time" },
    "risk_probability": { "type": "number", "minimum": 0, "maximum": 1 },
    "risk_band": { "enum": ["Low", "Moderate", "High", "Uncertain"] },
    "uncertainty": {
      "type": "object",
      "required": ["epistemic", "aleatoric", "credible_interval_95"],
      "properties": {
        "epistemic": { "type": "number", "description": "Ensemble disagreement estimate." },
        "aleatoric": { "type": "number", "description": "Irreducible noise estimate from calibration set." },
        "credible_interval_95": { "type": "array", "items": { "type": "number" }, "minItems": 2, "maxItems": 2 }
      }
    },
    "lead_time_estimate": {
      "type": "object",
      "required": ["median_hours", "ci_95"],
      "properties": {
        "median_hours": { "type": "number", "minimum": 0 },
        "ci_95": { "type": "array", "items": { "type": "number" }, "minItems": 2, "maxItems": 2 }
      }
    },
    "operating_threshold_version": { "type": "string", "description": "Locked threshold identifier; must match a record in the Threshold Registry." },
    "contributing_features": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "feature_name": { "type": "string" },
          "shapley_value": { "type": "number" },
          "domain": { "enum": ["facial", "rppg", "ocular", "tongue_oral", "clinical", "laboratory"] }
        }
      }
    },
    "model_card_uri": { "type": "string", "format": "uri" },
    "audit_trail_uri": { "type": "string", "format": "uri" }
  }
}
```

### 1.13 JSON Schema — QualityGateResult (auxiliary entity)

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://denguesense.reainmaker.ai/schema/QualityGateResult/v1.2.0",
  "title": "QualityGateResult",
  "type": "object",
  "required": ["session_id", "checked_at", "overall_status", "checks"],
  "properties": {
    "session_id": { "type": "string", "format": "uuid" },
    "checked_at": { "type": "string", "format": "date-time" },
    "overall_status": { "enum": ["PASS", "FAIL", "RECAPTURE"] },
    "checks": {
      "type": "array",
      "minItems": 9,
      "maxItems": 9,
      "items": {
        "type": "object",
        "required": ["check_id", "passed", "metric_value", "threshold"],
        "properties": {
          "check_id": { "enum": ["face_detection", "motion_headpose", "exposure_lighting", "framerate_compression", "rppg_snr", "occlusion", "ocular_segmentation", "tongue_segmentation", "duration_missing_frames"] },
          "passed": { "type": "boolean" },
          "metric_value": { "type": "number" },
          "threshold": { "type": "number" },
          "reason_code": { "type": "string" }
        }
      }
    },
    "recapture_instruction": { "type": "string" }
  }
}
```

### 1.14 Entity-Relationship Diagram (ASCII)

```
                         +-----------------------+
                         |       Participant     |
                         |  (pseudonymised)      |
                         +-----------+-----------+
                                     |
                                     | 1
                                     |
                                     | *
                        +------------+------------+
                        |       ScanSession      |
                        |  (uuid PK, site_code,  |
                        |   captured_at, schema)  |
                        +--+----+----+----+------+
                           |    |    |    |
              1            |    |    |    |            1
   +---------------------+  |    |    |    |  +---------------------+
   | ContextualMetadata |<>|    |    |    |<>| QualityGateResult   |
   +---------------------+  |    |    |    |  +---------------------+
                            |    |    |    |
                            |    |    |    |
                  1         |    |    |    |          1
   +---------------------+   |    |    |    |  +---------------------+
   |   CaptureArtefact   |<>-+    |    |    +<>|    RiskAssessment   |
   |  (per step video)  |        |    |       +----------+----------+
   +---------------------+        |    |                  |
                                  |    |                  | 1
                                  |    |                  |
                                  |    |       *----------+
                                  |    |
                  1               |    |
                  +---------------+    |
                  |                    |
              *   |                    |   *
   +----------+---v----+        +------v-----------+
   |   FeatureVector    |<------|  LabValue (rows) |
   |  (per modality)    |  *..1 +------------------+
   +---------+----------+
             | 1
             |
             | *
   +---------v-----------+
   |  AdjudicatedEndpoint|
   |  (24h composite)    |
   +---------------------+
```

Legend: `<>` = composition (child cannot exist without parent); `<->` = association; `1`/`*` cardinality. The Participant → ScanSession → FeatureVector → RiskAssessment chain is the core spine; QualityGateResult, CaptureArtefact, ContextualMetadata, LabValue, and AdjudicatedEndpoint hang off this spine. Endpoints are stored **separately** from feature vectors to prevent the model from accessing its own labels (Section 6.2).

### 1.15 Feature Catalog (Table)

| Domain | Feature | Type | Unit | Source Module | Locked At | Leakage Risk |
|--------|---------|------|------|---------------|-----------|--------------|
| Facial | forehead.regional_intensity[L\*a\*b\*] | numeric[3] | CIELAB | Facial Perfusion | G5 | Low |
| Facial | cheek.asymmetry_index | numeric | ratio | Facial Perfusion | G5 | Low |
| Facial | periorbital.perfusion_trend | numeric | Δintensity/s | Facial Perfusion | G5 | Medium |
| rPPG | heart_rate | numeric | bpm | rPPG Engine | G2 | Low |
| rPPG | hrv.rmssd | numeric | ms | rPPG Engine | G2 | Low |
| rPPG | ac_dc_ratio | numeric | ratio | rPPG Engine | G2 | Medium |
| rPPG | signal_quality.snr_db | numeric | dB | rPPG Engine | G1 | Low |
| Ocular | conjunctival_colour_lab | numeric[3] | CIELAB | Ocular Research | G5 | Low |
| Ocular | blink_rate_per_min | numeric | events/min | Ocular Research | G5 | Medium |
| Ocular | segmentation_confidence | numeric | [0,1] | Ocular Research | G5 | Low |
| Tongue/Oral | coating_coverage_pct | numeric | % | Tongue/Oral | T1–T6 | Medium |
| Tongue/Oral | visible_lesions[].lesion_type | enum[] | — | Tongue/Oral | T1–T6 | High (confounder) |
| Clinical | day_of_illness | integer | day | Clinical Data | G3 | Low |
| Clinical | pulse_pressure | integer | mmHg | Clinical Data | G3 | Medium |
| Clinical | warning_signs | enum[] | — | Clinical Data | G3 | High (post-outcome leak) |
| Laboratory | platelet_count | numeric | ×10⁹/L | Clinical Data | G2 | High (timing) |
| Laboratory | haematocrit | numeric | % | Clinical Data | G2 | High (timing) |
| Metadata | lighting_lux | numeric | lux | Capture/Guidance | G1 | Low |
| Metadata | camera_model | enum | — | Capture/Guidance | G1 | Medium (site artefact) |
| Target | risk_probability | numeric | [0,1] | Risk Engine | G5 | — |
| Target | risk_band | enum | — | Risk Engine | G5 | — |
| Target | lead_time_estimate.median_hours | numeric | hours | Risk Engine | G6 | — |

High-leakage-risk features (warning signs, post-scan lab values, treatment decisions) require a `feature_availability_timestamp` strictly before the prediction time; the leakage audit at G5 verifies this invariant holds across all training partitions.

---

## 2. Preprocessing & Pipelines

### 2.1 Data Cleaning Rules Per Modality

Each modality has a distinct cleaning protocol applied **before** the signal-quality gate to remove artefacts that would otherwise corrupt downstream feature extraction:

- **Video streams.** Drop frames with detection confidence <0.5; mark contiguous drops >0.5 s as gaps. Remove duplicate frames (perceptual-hash match). Resample to 30 fps via motion-compensated interpolation. Reject streams shorter than the per-step minimum (30 s neutral face, 8 s ocular, 8 s dorsal tongue).
- **rPPG.** Band-pass 0.7–3.5 Hz. Detrend with 6-s moving average. Clip motion artefact spikes >5× MAD and interpolate. Flag segments with motion artefact index >0.4 for downstream exclusion.
- **Facial regions.** Mask non-skin pixels. Discard samples with >20% region-mask occlusion in any frame. Apply chrominance skin-tone filter to exclude specular highlights and shadows.
- **Ocular.** Discard windows with conjunctival IoU <0.6. Remove blink-event frames from colour analysis.
- **Tongue/oral.** Reject frames where Brenner focus is below threshold; verify colour-reference card temperature matches calibration library before allowing colour features.
- **Clinical inputs.** Range-validate (systolic BP 40–250 mmHg, SpO₂ 50–100%, temperature 32–42 °C). Harmonise units at ingest. Flag out-of-range as `INVALID` rather than silently dropping.
- **Laboratory values.** Reflexivity checks (Hct ≈ 3 × Hb ± 3%). Reject post-prediction-timestamp values (leakage control). Accept multiple measurements with `timestamp` and `methodology`.
- **Metadata.** Coerce FPS to integer, resolution to `WxH`. Reject FPS <20 or resolution <640×480. Missing metadata replaced with explicit `null` and logged to deviation registry.

### 2.2 Normalization: Skin-Tone, Colour-Reference, Lighting Compensation

Three normalization passes are applied in a fixed order to make camera-derived signals comparable across participants, devices, and sites:

1. **Skin-tone normalization.** Each facial region's raw RGB is converted to chrominance-based YCgCr; the AC component (pulsatile) is divided by the DC component (mean skin reflectance), producing the AC/DC perfusion index. This cancels the dominant melanin effect on absolute intensity. Skin-tone category (Fitzpatrick I–VI proxy) is recorded as a subgroup variable — never used as a feature — to verify the model is not learning skin-tone artefacts.
2. **Colour-reference calibration.** When a colour-reference card is present in the tongue/oral capture (mandatory under SOP), its measured CIELAB values are used to compute a per-session affine colour-correction matrix applied to tongue body and coating. For ocular/facial regions without the card, a per-device baseline white-balance correction from a periodic calibration shoot is applied.
3. **Lighting compensation.** Per-frame illuminance estimated from a fixed neutral region (e.g., glabella); frame intensity normalised to a target illuminance. Lighting metadata (lux, K) logged as a covariate for subgroup analysis (R2 mitigation: poor signal quality in difficult lighting).

All normalization parameters are **fitted on training data only** (Section 7.2): colour-correction matrices from the calibration library are versioned and frozen; the locked pipeline at G5 applies the same matrices to validation, external, and prospective data without re-fitting.

### 2.3 Missing-Value Imputation & Train-Only Fitting

Imputation follows a strict, prespecified, train-only fitting rule. The DengueSense Statistical and ML Plan (Section 7.2) explicitly requires that **preprocessing, imputation, feature selection, and calibration are fitted on training data only**. Concretely:

- **Imputation model:** Per-feature median (continuous) or modal class (categorical) computed on the training partition, with a `missing_indicator` flag retained.
- **Multiple imputation (sensitivity):** For features with >20% training-partition missingness, an MICE model is fitted on training data only and applied (frozen) to test/external data. Primary analysis uses single-imputation; MICE is a robustness check.
- **Feature selection:** Penalised L1 regression within cross-validation on the training set only; the retained feature list is frozen before test-set access.
- **Calibration:** Post-hoc isotonic or Platt calibration fitted on the training partition via nested CV; calibration curve and Brier score computed **once** on the untouched internal test set (step 8).
- **Timestamp enforcement:** Every predictor carries a `feature_availability_timestamp`. The leakage audit (G5) verifies, for every row, that the earliest available timestamp precedes both the prediction time and the outcome adjudication window.

### 2.4 Real-Time Streaming Ingestion: 60–100 Second Capture Workflow

The capture workflow is designed to complete in approximately 60–100 seconds per assessment session, balancing clinical practicality with the data-quality requirements of the multimodal pipeline. It consists of seven sequential steps with defined duration targets and required controls (DengueSense Section 5.1):

| # | Step | Duration | Required Control |
|---|------|----------|------------------|
| 1 | Identity and study-ID check | 5 s | Study ID only in the capture interface (no PHI on device) |
| 2 | Positioning and lighting check | 5–10 s | Distance, framing, exposure, face visibility verified |
| 3 | Neutral facial recording | 30–45 s | Minimal movement, no talking |
| 4 | Ocular/conjunctival capture | 10 s | Safe, non-contact positioning; segmentation confirmation |
| 5 | Dorsal tongue capture | 10–15 s | Standardised lighting, colour control, focus, non-contact |
| 6 | Optional controlled task | 10 s | Only if justified in the approved protocol |
| 7 | Quality result | Immediate | Accept / Recapture-with-reason / Unable-to-acquire |

The streaming ingestion rules require: (a) each step's video is written to a per-step artefact store on device before transmission; (b) streaming upload begins only after step 7 returns `ACCEPT`; (c) on `RECAPTURE`, the failed step is re-run (maximum 2 recaptures per step before `UNABLE_TO_ACQUIRE`); (d) on `UNABLE_TO_ACQUIRE`, the system records an acquisition failure rather than forcing a result, ensuring clinicians are never presented with output derived from inadequate input data.

### 2.5 Signal-Quality Gate Enforcement (Nine Quality Checks)

Inference must be blocked when any critical quality rule fails. The Signal-Quality Engine evaluates nine checks, each producing a boolean `passed` and a reason code on failure:

1. **Face detection & region stability** — primary face detector confidence ≥0.9 across ≥90% of frames; facial landmark stability (no large jitter).
2. **Motion & head-pose limits** — translational motion <threshold; head yaw/pitch/roll within ±15°.
3. **Exposure & lighting consistency** — mean luminance within target band; no glare or shadow hot-spots; colour temperature within ±300 K of calibration.
4. **Frame rate & compression artefacts** — measured FPS ≥20; H.264 quantisation parameter below threshold; no dropped-frame gaps >0.5 s.
5. **rPPG signal-to-noise ratio & spectral plausibility** — SNR ≥ threshold dB; dominant spectral peak within 0.7–3.5 Hz; spectral plausibility ≥0.6.
6. **Occlusion from masks, glasses, hair** — required facial regions uncovered; conjunctival region unobstructed.
7. **Ocular segmentation confidence** — mean IoU ≥0.6 across the ocular step.
8. **Tongue segmentation with focus and colour-reference verification** — tongue mask IoU ≥0.7; Brenner focus ≥ threshold; colour-reference card within ΔE tolerance.
9. **Required duration & missing-frame detection** — actual step duration ≥ minimum; missing-frame fraction <5%.

Every rejection produces an **understandable reason code** and a **safe recapture instruction**. After the approved maximum attempts, the system records an acquisition failure rather than forcing a result (Section 5.2).

### 2.6 Feature-Extraction Pipeline Diagram (ASCII)

```
+-----------+     +----------------+     +-------------------+     +---------------------+
|  Raw      |---->|   Quality      |---->|  Region           |---->|  Feature            |
|  Video +  |     |   Gate         |     |  Segmentation     |     |  Extraction         |
|  Metadata |     |  (9 checks)   |     |  (face/ocular/     |     |  (rPPG, perfusion,  |
+-----------+     +-------+--------+     |   tongue)         |     |   ocular, tongue)   |
                          |              +-------------------+     +----------+----------+
                          |                                                    |
                          |                                                    v
                       FAIL|                                              +-----+-----+
                          |                                              |  Normal-  |
                          v                                              |  isation  |
                  +----------------+                                     |  (skin-   |
                  | Recapture or   |                                     |   tone,   |
                  | UnableToAcquire|                                     |   colour, |
                  +----------------+                                     |   light)  |
                                                                         +-----+-----+
                                                                               |
                                                                               v
                                                                         +-----+-----+
                                                                         |  Feature  |
                                                                         |  Vector  |
                                                                         |  (locked |
                                                                         |   schema)|
                                                                         +-----+-----+
                                                                               |
                                                                               v
                                                                         +-----+-----+
                                                                         |   Risk    |
                                                                         |  Engine   |
                                                                         +-----------+
```

### 2.7 Preprocessing Pipeline (Python Pseudo-code)

```python
"""
beAIve DengueSense preprocessing pipeline.
All transforms are fitted on TRAIN partition only and frozen at lock time.
Versioned via `pipeline_version`; any change re-opens stage gate G5.
"""
from typing import Optional
from pydantic import BaseModel

class LockedPipeline(BaseModel):
    pipeline_version: str
    skin_tone_norm_params: dict   # fitted on train
    colour_correction_matrices: dict[str, list]  # per-device, fitted on train
    imputation_params: dict       # medians & modal classes from train
    feature_list: list[str]       # frozen feature set selected on train
    calibration_map: dict         # isotonic fitted on train

def run_pipeline(session: ScanSession, lock: LockedPipeline) -> FeatureVector:
    # 1. Quality gate (9 checks). Block inference on any fail.
    qgr = quality_engine.evaluate(session, checks=ALL_NINE_CHECKS)
    if qgr.overall_status != "PASS":
        if session.attempts < MAX_ATTEMPTS:
            raise RecaptureRequired(qgr.recapture_instruction)
        raise UnableToAcquire(qgr.reason_codes)

    # 2. Per-step cleaning and resampling
    cleaned = {}
    for step_name, video in session.steps.items():
        v = drop_low_confidence_frames(video, conf=0.5)
        v = resample_canonical(v, fps=30)
        v = mask_non_skin(v)
        cleaned[step_name] = v

    # 3. Skin-tone normalisation (AC/DC ratio per region) — using frozen params
    facial = facial_perfusion.extract(cleaned["neutral_face"],
                                      norm_params=lock.skin_tone_norm_params)

    # 4. Colour-reference calibration (tongue/oral) — using frozen per-device matrix
    device_matrix = lock.colour_correction_matrices[session.metadata.camera_model]
    tongue = tongue_oral.extract(cleaned["dorsal_tongue"],
                                 colour_matrix=device_matrix,
                                 focus_threshold=BRENNER_MIN)

    # 5. rPPG extraction
    rppg = rppg_engine.extract(cleaned["neutral_face"], band=(0.7, 3.5))

    # 6. Ocular extraction
    ocular = ocular_module.extract(cleaned["ocular_capture"],
                                   min_iou=0.6)

    # 7. Assemble feature vector with availability timestamps
    fv = FeatureVector(
        session_id=session.session_id,
        schema_version=FEATURE_VECTOR_SCHEMA_VERSION,
        pipeline_version=lock.pipeline_version,
        facial_regions=facial,
        rppg=rppg,
        ocular=ocular,
        tongue_oral=tongue,
        clinical=session.clinical_inputs,
        laboratory=session.lab_values,
        feature_availability_timestamps=build_timestamp_map(session),
    )

    # 8. Missing-value imputation (frozen medians/modes from train)
    fv = imputer.apply(fv, params=lock.imputation_params)

    # 9. Project to frozen feature list (no selection at inference time)
    fv = fv.project(features=lock.feature_list, strict=True)

    return fv


def risk_assessment(fv: FeatureVector, lock: LockedPipeline,
                    threshold_version: str) -> RiskAssessment:
    # Model produces raw probability
    raw_prob = locked_model.predict_proba(fv.to_matrix())   # frozen at G5
    # Calibration (isotonic) fitted on train only
    calibrated_prob = lock.calibration_map["isotonic"].transform(raw_prob)
    # Band assignment using locked thresholds
    band = assign_band(calibrated_prob, threshold_version,
                       uncertainty=fv.uncertainty_estimate())
    return RiskAssessment(
        session_id=fv.session_id,
        risk_probability=calibrated_prob,
        risk_band=band,
        uncertainty=fv.uncertainty_estimate(),
        lead_time_estimate=lead_time_model.predict(fv),
        operating_threshold_version=threshold_version,
    )
```

### 2.8 State-Flow Diagram (ASCII) — Scan Lifecycle

```
                 [Start Capture]
                       |
                       v
              +--------+--------+
              | identity_check  |  5s
              +--------+--------+
                       |
                       v
              +--------+--------+
              |  positioning    |  5-10s
              +--------+--------+
                       |
                       v
              +--------+--------+
              |  neutral_face   |  30-45s
              +--------+--------+
                       |
                       v
              +--------+--------+
              |  ocular_capture  |  10s
              +--------+--------+
                       |
                       v
              +--------+--------+
              |  dorsal_tongue   |  10-15s
              +--------+--------+
                       |
                       v
              +--------+--------+
              | controlled_task? |  10s (optional)
              +--------+--------+
                       |
                       v
              +--------+--------+
              |  quality_gate   |  (9 checks, immediate)
              +--------+--------+
                       |
            PASS       |       FAIL
       +---------------+----------------+
       |                                |
       v                                v
+------+------+                  +-----+------+
| Feature     |                  | Recapture |  (max 2/step)
| Extraction  |                  +-----+------+
+------+------+                        |
       |                               v
       v                        +-----+------+
+------+------+                 | attempts   |
| Risk        |                 | exceeded?  |
| Assessment  |                 +--+------+--+
+------+------+                  |      |
       |                         No     Yes
       v                          |      |
+------+------+                   v      v
|  Record on  |          +-------+--+   +-----+-----+
|   Dashboard |          | Recapture|   | UNABLE_TO |
+-------------+          +-----------+   | _ACQUIRE  |
                                         +-----------+
```

---

## 3. Evaluation Metrics & Threshold Triggers

Performance reporting follows the categories defined in DengueSense Section 7.3 and adheres to TRIPOD+AI transparent reporting standards throughout, with PROBAST+AI used during protocol design and independent risk-of-bias review.

### 3.1 Discrimination Metrics

- **AUROC** with 95% CI computed via clustered bootstrap (B=2000, clustered by participant to account for repeated scans).
- **AUPRC** with the same clustered bootstrap, reported because the primary endpoint is rare (event-rate estimate from feasibility G4) and AUROC alone can overstate performance in imbalanced settings.

### 3.2 Clinical Operating Point Metrics

At the locked operating threshold (selected at step 7 of the analysis sequence), the following are reported with 95% CIs:

| Metric | Definition | Target (G6) |
|--------|------------|-------------|
| Sensitivity | P(predicted High \| true deterioration within 24 h) | ≥ prespecified sensitivity floor (biostatistician-set) |
| Specificity | P(predicted not-High \| no deterioration within 24 h) | balanced against alert burden |
| PPV | P(true deterioration \| predicted High) | meets false-alert budget |
| NPV | P(no deterioration \| predicted not-High) | clinically acceptable for triage discharge |
| Alert rate | Proportion of scans producing a High band | monitored for operational burden |

### 3.3 Calibration Metrics

- **Calibration intercept & slope** from a logistic regression of the binary outcome on the logit of predicted probability (perfect: intercept 0, slope 1).
- **Calibration plot** — observed event rate vs. predicted probability, in deciles and as a smooth LOESS curve.
- **Brier score** and **Brier skill score** relative to the base-rate reference.

### 3.4 Operational Value Metrics

| Metric | Definition |
|--------|------------|
| Alert rate | High-band outputs per 100 scans |
| False alerts per patient-day | False-High outputs ÷ patient-days monitored |
| Recapture rate | Sessions requiring recapture ÷ total sessions |
| Result availability time | Wall-clock time from session start to RiskAssessment emitted |

### 3.5 Timeliness Metrics

- **Median lead time** before clinical endpoint, in hours.
- **Distribution** (IQR, 5th–95th percentile) of lead time before endpoint.
- **Censored handling** — for scans not followed by an endpoint, lead time is right-censored and Kaplan–Meier-style reporting is used.

### 3.6 Incremental Value Metrics

The full multimodal model is compared against the clinical-only baseline (step 4 vs. step 6 of the analysis sequence) via ΔAUROC, ΔAUPRC, and **decision-curve analysis** (net benefit vs. threshold probability, with treat-all/none references).

### 3.7 Subgroup Performance

Subgroup performance is reported across: **Site** (each participating site, plus site-held-out validation); **Device** (each camera model in the deployment fleet); **Sex** (female, male, not stated); **Age band** (paediatric <18, adult 18–64, older ≥65); **Skin-tone category** (Fitzpatrick I–VI proxy, with explicit analysis of R2 mitigation: poor signal quality in darker skin tones). Subgroup AUROC and calibration are reported with 95% CIs; prespecified uncertainty bands (e.g., subgroup AUROC lower 95% CI within 0.05 of overall) must be met at G6 for progression to prospective silent validation.

### 3.8 Reporting Standards

All development and validation reports conform to **TRIPOD+AI** (Transparent Reporting of a multivariable prediction model for Individual Prognosis or Diagnosis, AI extension). **PROBAST+AI** (risk-of-bias tool for AI-based prediction models) is applied during protocol design and as an independent risk-of-bias review before any clinical claim. Supplementary artefacts include a model card (referenced in every `RiskAssessment` payload via `model_card_uri`), data sheet, and per-modality segmentation cards.

### 3.9 Threshold-Trigger Table

| Metric | Target | Action if Breached |
|--------|--------|--------------------|
| AUROC (internal test) | ≥ lower 95% CI of development-set AUROC − 0.03 | Halt progression to G6; review calibration drift and site artefacts |
| AUPRC (internal test) | ≥ prespecified floor from SAP | Re-evaluate feature selection; consider pausing Level-4 deep-learning extension |
| Sensitivity at locked threshold | ≥ sensitivity floor | Lower operating threshold; recompute alert burden; biostatistician sign-off required |
| Specificity at locked threshold | ≥ specificity floor | Raise operating threshold; verify no subgroup collapse |
| Calibration slope | 0.9–1.1 | Re-fit isotonic calibration **on training data only**; re-lock |
| Brier score | ≤ prespecified ceiling | Investigate overfitting; restrict feature set |
| Subgroup AUROC lower 95% CI | Within 0.05 of overall | Hold subgroup-specific model card; consider narrowing intended-use population |
| Skin-tone subgroup AUROC gap | ≤ 0.05 between highest and lowest Fitzpatrick band | R2 mitigation: balanced recruitment, improved capture guidance, lighting hardening |
| Recapture rate | ≤ 20% per site | Re-train capture operators; investigate device/lighting failure modes |
| False alerts per patient-day | ≤ operational ceiling | Tighten specificity; investigate clustering; consider escalation-policy revision |
| Result availability time | ≤ 30 s from session end to RiskAssessment emitted | Profile pipeline; offload heavy feature extraction; reconsider server capacity |
| Scan success rate | ≥ 90% of attempted sessions produce analysable signal | Site re-training; device audit; revisit protocol deviations |
| Lead-time median | ≥ 6 h before 24-h endpoint | Review endpoint window; investigate silent-validation data flow; re-threshold |

### 3.10 Testing Matrix Applied to the ML Pipeline (adapted from Vibe Coding §10)

The Vibe Coding testing matrix (Unit, Integration, E2E, Performance, Security) is adapted to the beAIve DengueSense ML pipeline, treating it as a software system with the additional disciplines of analytical and clinical validation.

| Test Layer | Scope | Tooling | Coverage Target | Frequency | ML-Pipeline-Specific Tests |
|------------|-------|---------|-----------------|-----------|----------------------------|
| **Unit** | Feature extractors, imputation, calibration, threshold-to-band | pytest + Hypothesis | 80%+ line coverage on `feature_*`, `pipeline`, `risk_engine` | Every commit | Schema-conformance vs `FeatureVector`/`RiskAssessment`; `feature_availability_timestamp` ≤ prediction time; skin-tone normalisation symmetry; deterministic for frozen inputs |
| **Integration** | End-to-end feature extraction from raw video to FeatureVector; Risk Engine call; DB write/read | pytest + Supertest-style fixtures; containerised feature store | All critical paths (capture → gate → extract → risk → audit) | Every PR | Quality-gate enforcement (all 9 checks fail-state); recapture flow; unable-to-acquire flow; train-only-imputation invariants (test-set uses frozen params) |
| **E2E** | Full 60–100 s capture session on real device → dashboard | Playwright/Cypress; physical-device capture harness | All Must-Have stories (capture, dashboard, audit, model card) | Every sprint | Synthetic-participant capture; end-to-end scan with seeded labs; locked-model reproducibility (same scan → same `risk_probability` to 6 d.p.) |
| **Performance** | Throughput of feature extraction; latency to RiskAssessment | k6 / Locust; Lighthouse | Inference p95 ≤ 5 s; dashboard TTI ≤ 3 s | Weekly / pre-launch | Load test concurrent sessions at peak site load; rPPG CPU profile; large-cohort batch re-processing window |
| **Security** | Vulnerabilities, secrets, PHI leakage | Snyk, OWASP ZAP, secret scanners | Zero high/critical | Every sprint | PHI-in-field tests (no direct identifiers in `ScanSession`); pseudonymisation reversibility; access-control (operator cannot read another site's data); audit-trail immutability; model-exfiltration (cannot extract training data via API) |
| **Visual Regression** | Dashboard rendering consistency | Chromatic / Percy | All design components | Every PR | Risk-band colour consistency across dark/light mode; uncertainty CI rendering; audit-trail timeline rendering |
| **Analytical Validation** (clinical-extension layer) | rPPG reference-device agreement; repeatability; bias review | Per-protocol analytical validation harness, biostatistician-approved | Per DengueSense Section 4 / Phase 3 | Phase 3 (M4–M7) and on any model change | Bland–Altman vs. reference ECG/pulse-oximeter; ICC for repeated scans; subgroup bias review |
| **Clinical Validation** (clinical-extension layer) | Locked-model performance on internal test, external site, prospective silent validation | Frozen pipeline; blinded test-set custodian | Prespecified sensitivity, calibration, false-alert, subgroup uncertainty targets | G5, G6, G7 | Leakage audit; endpoint adjudication independence; decision-curve analysis; TRIPOD+AI checklist; PROBAST+AI risk-of-bias review |

### 3.11 Pre-Deployment Testing Checklist (ML pipeline analogue of Vibe Coding §10.1)

| Category | Specific Checks | Pass Criteria |
|---------|-----------------|---------------|
| Functional | Must-Have features working (capture, gate, extract, risk, dashboard, audit) | Zero critical/major defects |
| Cross-Device | Each camera model in fleet | Consistent extraction within tolerance |
| Performance | Inference p95; dashboard TTI | p95 ≤ 5 s; TTI ≤ 3 s |
| Calibration | Calibration slope, Brier | Within prespecified thresholds |
| Subgroup | AUROC/AUPRC/calibration across site/device/sex/age/skin-tone | Within uncertainty bands |
| Security | No high/critical; PHI handling | Snyk + OWASP ZAP clean; pseudonymisation audit passed |
| Leakage | `feature_availability_timestamp` precedes prediction time | 100% conformance on test set |
| Reproducibility | Same scan → same `risk_probability` | Bitwise-identical for locked pipeline |
| External Validation | Locked pipeline at independent site | G6 passed |
| Prospective Silent | Real-time, non-interventional | G7 passed |

---

## 4. Change Control & Cross-References

Any change to a JSON Schema, the feature list, the pipeline version, or the operating threshold re-opens the relevant stage gate (G1 capture/SQI, G2 analytical validation, G5 model lock, G6 external validation, G7 prospective silent validation). Biostatistician and Regulatory lead jointly sign off the schema-version bump and update the Threshold Registry; post-G5 data must use the identical frozen `pipeline_version`. Cross-references: Doc 01 (System Architecture); Doc 02 (Agentic Workflow); Doc 04 (API Reference, contracts for `/scan`, `/feature-vector`, `/risk-assessment`, `/quality-gate`); Doc 05 (DevOps/MLOps CI-CD); Doc 06 (Security & Compliance, MDA/NMRR/MREC, ISO/IEC 27001, PDPA 2010 + 2024 amendment).

---

*End of Document 03.*
