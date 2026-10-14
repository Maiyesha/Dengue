# Deployment, DevOps, & Infrastructure Blueprint

**Document 05 of 07 — beAIve DengueSense × Vibe Coding Technical Suite**
**Status:** Authoritative DevOps baseline for the eighteen-month programme
**Scope:** Production deployment, container orchestration, CI/CD, observability, and clinical-audit logging for the DengueSense clinical decision-support system (CDSS)
**Classification:** Internal / Project Reference — Regulatory Engineering
**Version:** 1.0 (aligned with DengueSense v2.1, Vibe Coding v2.0)

---

## 0. Document Purpose and Operating Principles

This blueprint specifies the deployment topology, CI/CD pipeline, and observability stack for beAIve DengueSense — an investigational, multimodal clinical decision-support tool combining camera-based physiological signals (rPPG, facial perfusion, ocular, tongue/oral, optical haematology) with conventional clinical inputs to estimate dengue deterioration risk. Its DevOps practices satisfy two overlaid requirement sets: (1) the agile, environment-parity, test-first deployment discipline from *Vibe Coding* (§10, §11, §15); (2) the regulated, stage-gated, evidence-anchored framework from the DengueSense Technical Documentation (§9, §8.2, §11).

Five operating principles govern this blueprint:

1. **Environment parity.** Vibe Coding §12.2 prescribes Docker for all environments to defeat "works on my machine". Every microservice runs in identical containers across `denguesense-dev`, `denguesense-staging`, and `denguesense-prod`. Permitted differences: configuration, secrets, scale.
2. **Stage-gate alignment.** Every CI/CD stage maps to one of nine DengueSense stage gates (G0–G8). Production deployments require recorded G8 regulatory sign-off in the audit log.
3. **Test-first delivery.** Vibe Coding's testing matrix (§10) is enforced as a quality gate: unit ≥ 80% coverage/commit, integration tests for every critical path/PR, E2E for every Must-Have story/sprint, zero high/critical security findings/sprint.
4. **Clinical traceability.** Every model decision, clinician action, and data-access event is written to an immutable, append-only audit log cryptographically separate from operational logs — satisfying ISO 13485 traceability and post-market surveillance.
5. **Reversibility.** No production change is irreversible. Blue-green deployments, automated rollback on health-check failure, model version pinning, and tested restore procedures (RTO < 4 h, Vibe Coding §4.2) ensure return to a known-good state.

---

## 1. Environment Setup: Containerization & Orchestration

### 1.1 Module-to-Container Mapping

The DengueSense architecture is decomposed into independently deployable services, each owning its data boundary, exposing a versioned API, and shipping as an OCI container image. The table maps the ten functional modules to their containerised runtime.

| # | Functional Module | Container Image | Base Image | Primary Runtime | GPU Required | Persistence |
|---|---|---|---|---|---|---|
| 1 | Capture Service | `denguesense/capture-svc` | `node:20-bookworm-slim` | Node.js / Fastify | No | Object storage (raw video) |
| 2 | Signal-Quality Engine | `denguesense/sqi-engine` | `python:3.11-slim` | Python / FastAPI | Opt (CUDA) | PV for QC reports |
| 3 | rPPG Engine | `denguesense/rppg-engine` | `nvidia/cuda:12.3.1-runtime-ubuntu22.04` | Python / ONNX Runtime | Yes | Model artifact PV |
| 4 | Facial Perfusion | `denguesense/perfusion-engine` | `nvidia/cuda:12.3.1-runtime-ubuntu22.04` | Python / PyTorch | Yes | Model artifact PV |
| 5 | Ocular Module | `denguesense/ocular-engine` | `python:3.11-slim` | Python / OpenCV | Opt | Model artifact PV |
| 6 | Tongue / Oral Module | `denguesense/tongue-engine` | `python:3.11-slim` | Python / OpenCV + timm | Opt | Model artifact PV |
| 7 | Optical Haematology | `denguesense/optical-haem-engine` | `python:3.11-slim` | Python / scikit-learn | No | Model artifact PV |
| 8 | Clinical Data Service | `denguesense/clinical-svc` | `node:20-bookworm-slim` | Node.js / Fastify | No | PostgreSQL (clinical) |
| 9 | Risk Engine | `denguesense/risk-engine` | `python:3.11-slim` | Python / FastAPI | Yes (infer) | Model artifact PV + PG |
| 10 | Research Dashboard | `denguesense/dashboard` | `node:20-bookworm-slim` | Next.js 14 / React | No | None (stateless) |

Supporting infrastructure — PostgreSQL 16, Redis 7, MLflow, Prometheus, Grafana, Loki, Tempo, Sentry — deploy alongside.

### 1.2 Risk Engine Dockerfile (Complete, Production-Ready)

The Risk Engine fuses approved variables from each upstream modality and produces a probability, risk band, and uncertainty estimate. The Dockerfile below is the authoritative reference for the service.

```dockerfile
# syntax=docker/dockerfile:1.7
# Risk Engine — DengueSense. Multi-stage build.
# Regulatory note: image digest is recorded at build time and pinned in the
# deployment manifest. Any digest change requires a fresh G7/G8 review.

ARG PYTHON_VERSION=3.11.9
ARG CUDA_VERSION=12.3.1

# ---------- Stage 1: builder ----------
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu22.04 AS builder
ARG PYTHON_VERSION
ENV DEBIAN_FRONTEND=noninteractive PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        python${PYTHON_VERSION%.*} python${PYTHON_VERSION%.*}-venv python${PYTHON_VERSION%.*}-dev \
        build-essential curl ca-certificates libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/* \
    && python${PYTHON_VERSION%.*} -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /build
COPY pyproject.toml uv.lock ./
RUN pip install --upgrade pip==24.2 setuptools==75.1.0 wheel==0.44.0 \
    && pip install --no-cache-dir -r <(uv export --no-dev --format requirements-txt)
COPY src/ ./src/
COPY alembic.ini ./
COPY alembic/ ./alembic/
RUN pip install --no-cache-dir ./src

# ---------- Stage 2: runtime ----------
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu22.04 AS runtime
ARG PYTHON_VERSION
LABEL org.opencontainers.image.title="denguesense/risk-engine" \
      org.opencontainers.image.source="https://github.com/reainmaker/denguesense" \
      org.opencontainers.image.licenses="Proprietary" \
      org.opencontainers.image.vendor="reAInmaker SDN BHD" \
      org.opencontainers.image.usage="RUO — Research Use Only until G8 sign-off"
ENV DEBIAN_FRONTEND=noninteractive PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}" APP_ENV=production

# Non-root user. UID/GID 10001 fixed for predictable volume permissions.
RUN groupadd --system --gid 10001 dengue \
    && useradd --system --uid 10001 --gid dengue --home-dir /app --shell /usr/sbin/nologin dengue \
    && apt-get update && apt-get install -y --no-install-recommends \
        python${PYTHON_VERSION%.*} libgl1 libglib2.0-0 curl tini \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv
WORKDIR /app
COPY --chown=dengue:dengue src/ ./src/
COPY --chown=dengue:dengue alembic.ini ./
COPY --chown=dengue:dengue alembic/ ./alembic/
COPY --chown=dengue:dengue config/ ./config/
USER dengue
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8000/health || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["uvicorn", "src.risk_engine.main:app", \
     "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "4", "--proxy-headers", \
     "--log-config", "config/logging.json"]
```

Key properties: multi-stage build (~6 GB → ~1.4 GB); non-root (UID/GID 10001); `tini` as PID 1; pinned base images by digest (`@sha256:...`); HEALTHCHECK via `/health`; structured JSON logging from `config/logging.json`.

### 1.3 docker-compose.yml for Local Development

The compose file bootstraps the full local stack: ten application services plus PostgreSQL, Redis, MLflow, MinIO (S3-compatible object storage), and the observability baseline. This implements Vibe Coding's "Use Docker for all environments" — what runs in compose ships to Kubernetes.

```yaml
# docker-compose.yml — DengueSense local dev stack
version: "3.9"

x-gpu-deploy: &gpu-deploy
  resources:
    reservations:
      devices: [{ driver: nvidia, count: 1, capabilities: [gpu] }]

x-app-env: &app-env
  APP_ENV: dev
  LOG_LEVEL: DEBUG
  OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4317
  POSTGRES_HOST: postgres
  POSTGRES_DB: denguesense
  REDIS_URL: redis://redis:6379/0
  S3_ENDPOINT: http://minio:9000
  MLFLOW_TRACKING_URI: http://mlflow:5000

services:
  postgres:
    image: postgres:16.4-alpine
    environment: { POSTGRES_DB: denguesense, POSTGRES_USER: dengue_app, POSTGRES_PASSWORD: dev_only_change_me }
    volumes: [pgdata:/var/lib/postgresql/data, ./infra/sql/init/:/docker-entrypoint-initdb.d/:ro]
    ports: ["5432:5432"]
    healthcheck: { test: ["CMD-SHELL", "pg_isready -U dengue_app -d denguesense"], interval: 10s, timeout: 5s, retries: 5 }

  redis: { image: redis:7.4-alpine, command: ["redis-server", "--appendonly", "yes"], volumes: ["redisdata:/data"], ports: ["6379:6379"] }

  minio:
    image: minio/minio:RELEASE.2024-09-22T00-33-43Z
    command: server /data --console-address ":9001"
    environment: { MINIO_ROOT_USER: dengue_admin, MINIO_ROOT_PASSWORD: dev_only_change_me }
    volumes: ["miniodata:/data"]
    ports: ["9000:9000", "9001:9001"]

  mlflow:
    image: ghcr.io/mlflow/mlflow:v2.17.0
    command: sh -c "pip install psycopg2-binary boto3 && mlflow server --backend-store-uri postgresql://dengue_app:dev_only_change_me@postgres/mlflow --artifacts-destination s3://mlflow-artifacts --serve-artifacts --host 0.0.0.0 --port 5000"
    environment: { MLFLOW_S3_ENDPOINT_URL: http://minio:9000, AWS_ACCESS_KEY_ID: dengue_admin, AWS_SECRET_ACCESS_KEY: dev_only_change_me }
    depends_on: [postgres, minio]
    ports: ["5000:5000"]

  capture-svc:        { build: ./services/capture,        environment: <<: *app-env, depends_on: [postgres, redis, minio] }
  sqi-engine:         { build: ./services/sqi,            environment: <<: *app-env, depends_on: [minio, redis] }
  rppg-engine:        { build: ./services/rppg,            environment: <<: *app-env, depends_on: [minio, mlflow], deploy: *gpu-deploy }
  perfusion-engine:   { build: ./services/perfusion,      environment: <<: *app-env, depends_on: [minio, mlflow], deploy: *gpu-deploy }
  ocular-engine:      { build: ./services/ocular,         environment: <<: *app-env, depends_on: [minio] }
  tongue-engine:      { build: ./services/tongue,         environment: <<: *app-env, depends_on: [minio] }
  optical-haem-engine: { build: ./services/optical-haem,  environment: <<: *app-env, depends_on: [minio] }
  clinical-svc:       { build: ./services/clinical,       environment: <<: *app-env, depends_on: [postgres, redis] }
  risk-engine:
    build: ./services/risk-engine
    environment:
      <<: *app-env
      RISK_MODEL_VERSION: "2026.08.0"
    volumes: ["./models:/models:ro"]
    depends_on: [postgres, redis, mlflow]
    ports: ["8000:8000"]
    deploy: { resources: { reservations: { devices: [{ driver: nvidia, count: 1, capabilities: [gpu] }] } } }
  dashboard:          { build: ./services/dashboard,      environment: <<: *app-env, depends_on: [risk-engine, clinical-svc], ports: ["3000:3000"] }

  prometheus:   { image: prom/prometheus:v2.54.1, volumes: ["./infra/prometheus.yml:/etc/prometheus/prometheus.yml:ro"], ports: ["9090:9090"] }
  grafana:      { image: grafana/grafana:11.2.0, environment: { GF_SECURITY_ADMIN_PASSWORD: dev_only }, ports: ["3001:3000"] }
  loki:         { image: grafana/loki:3.1.1, ports: ["3100:3100"] }
  otel-collector: { image: otel/opentelemetry-collector-contrib:0.108.0, volumes: ["./infra/otel-collector.yml:/etc/otelcol/config.yml:ro"], ports: ["4317:4317"] }

volumes:
  pgdata:
  redisdata:
  miniodata:
```

### 1.4 Kubernetes Orchestration: Namespace Structure

Three namespaces provide environment isolation on a shared cluster, each with NetworkPolicy, ResourceQuota, LimitRange, RBAC RoleBinding, and image-pull-secret.

| Namespace | Purpose | Stage-Gate Bound | Image Promotion Rule | Resource Quota (CPU/Mem/GPU) |
|---|---|---|---|---|
| `denguesense-dev` | Engineering integration; nightly training | G0 → G4 | Any merged commit on `main` auto-deployed | 16 vCPU / 32 GiB / 1 GPU |
| `denguesense-staging` | Pre-prod validation; UAT and external validation | G5 → G7 | Tagged RCs (`vX.Y.Z-rc.N`) only | 32 vCPU / 64 GiB / 2 GPU |
| `denguesense-prod` | Live clinical at Malaysian hospital sites | G7 → G8 | Tagged releases (`vX.Y.Z`) with G8 sign-off | 64 vCPU / 128 GiB / 4 GPU |

Cross-namespace traffic is denied by default and allowed only via a single egress gateway. `denguesense-prod` adds admission control: OPA Gatekeeper refuses pods lacking `data-protection-class` label, signed image digest, or `clinical-audit-logging: enabled` annotation.

### 1.5 Kubernetes Deployment YAML — Risk Engine

```yaml
# k8s/prod/risk-engine-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: risk-engine
  namespace: denguesense-prod
  labels: { app.kubernetes.io/name: risk-engine, app.kubernetes.io/part-of: denguesense, app.kubernetes.io/component: inference, data-protection-class: clinical-pseudonymised }
spec:
  replicas: 3
  strategy: { type: RollingUpdate, rollingUpdate: { maxSurge: 1, maxUnavailable: 0 } }
  selector: { matchLabels: { app.kubernetes.io/name: risk-engine } }
  template:
    metadata:
      labels: { app.kubernetes.io/name: risk-engine, data-protection-class: clinical-pseudonymised, clinical-audit-logging: enabled }
      annotations: { prometheus.io/scrape: "true", prometheus.io/port: "8000", prometheus.io/path: "/metrics" }
    spec:
      serviceAccountName: risk-engine-sa
      imagePullSecrets: [{ name: ghcr-pull-secret }]
      nodeSelector: { accelerator: nvidia-a10g, workload-class: ml-inference }
      tolerations:
        - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - { labelSelector: { matchLabels: { app.kubernetes.io/name: risk-engine } }, topologyKey: kubernetes.io/hostname }
      securityContext: { runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, fsGroup: 10001, seccompProfile: { type: RuntimeDefault } }
      initContainers:
        - name: db-migrate
          image: ghcr.io/reainmaker/denguesense/risk-engine:v2026.8.0@sha256:abcd...
          command: ["alembic", "upgrade", "head"]
          env:
            - { name: POSTGRES_HOST, valueFrom: { secretKeyRef: { name: risk-engine-prod-secrets, key: pg-host } } }
            - { name: POSTGRES_PASSWORD, valueFrom: { secretKeyRef: { name: risk-engine-prod-secrets, key: pg-password } } }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      containers:
        - name: risk-engine
          image: ghcr.io/reainmaker/denguesense/risk-engine:v2026.8.0@sha256:abcd...
          imagePullPolicy: IfNotPresent
          ports: [{ name: http, containerPort: 8000 }]
          env:
            - { name: APP_ENV, value: production }
            - { name: RISK_MODEL_VERSION, value: "2026.08.0" }
            - { name: OTEL_EXPORTER_OTLP_ENDPOINT, value: http://otel-collector.observability.svc:4317 }
            - { name: POSTGRES_HOST, valueFrom: { secretKeyRef: { name: risk-engine-prod-secrets, key: pg-host } } }
          resources:
            requests: { cpu: "1000m", memory: "2Gi", nvidia.com/gpu: 1 }
            limits:   { cpu: "4000m", memory: "8Gi", nvidia.com/gpu: 1 }
          volumeMounts:
            - { name: model-artifacts, mountPath: /models, readOnly: true }
            - { name: tmp, mountPath: /tmp }
            - { name: dshm, mountPath: /dev/shm }
          probes:
            liveness:  { httpGet: { path: /health, port: http }, initialDelaySeconds: 30, periodSeconds: 15, failureThreshold: 3 }
            readiness: { httpGet: { path: /ready, port: http }, initialDelaySeconds: 10, periodSeconds: 10, failureThreshold: 2 }
            startup:   { httpGet: { path: /health, port: http }, failureThreshold: 30, periodSeconds: 10 }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      volumes:
        - { name: model-artifacts, persistentVolumeClaim: { claimName: risk-engine-models-pvc } }
        - { name: tmp, emptyDir: { medium: Memory, sizeLimit: 256Mi } }
        - { name: dshm, emptyDir: { medium: Memory, sizeLimit: 1Gi } }
---
apiVersion: v1
kind: Service
metadata: { name: risk-engine, namespace: denguesense-prod }
spec:
  selector: { app.kubernetes.io/name: risk-engine }
  ports: [{ name: http, port: 80, targetPort: 8000 }]
  type: ClusterIP
```

> An accompanying `HorizontalPodAutoscaler` scales the Deployment from 3 to 12 replicas based on CPU (target 65%) and memory (target 75%) utilisation.

### 1.6 Service Mesh: Ingress → API Gateway → Microservices

A single NGINX Ingress Controller terminates TLS at the cluster edge (certificates via cert-manager, automating Vibe Coding §11.4 Certbot). Behind the ingress, an internal API Gateway (Kong or Envoy) enforces authentication, rate-limiting, and WAF rules. Microservices are exposed only via ClusterIP — never directly reachable externally.

Traffic flow for a clinical risk-score request:

1. **Edge TLS.** `https://denguesense.<hospital-domain>.my` → NGINX Ingress (TLS 1.3, HSTS).
2. **WAF + rate limit.** Kong applies OWASP CRS, validates JWT (hospital IdP), 30 req/min per-clinician.
3. **Route.** `POST /v1/scans/{id}/risk-score` → `risk-engine.denguesense-prod.svc`.
4. **Inference.** Risk Engine calls `clinical-svc` and pulls pre-computed features from the five modality engines via gRPC.
5. **Audit.** Risk Engine writes a decision record to the audit log **before** returning the response.
6. **Telemetry.** OTel spans fan out to Prometheus/Loki/Tempo.

### 1.7 Storage Architecture

| Data Class | Storage Backend | Encryption | Retention | Backup Cadence |
|---|---|---|---|---|
| Raw scan video | S3-compatible (MinIO on-prem / AWS S3) | AES-256 + KMS | 7 years | Cross-region replication continuous |
| Derived features & QC | PostgreSQL 16 (clinical) | TDE + TLS | 7 years | Daily snapshot + WAL PITR |
| Model artifacts | PV on GPU nodes + MLflow store | AES-256 | Permanent | Daily snapshot |
| Clinical audit log | Separate PostgreSQL, append-only | TDE + column-level | 10 years | Continuous WAL + daily snapshot |
| Operational logs | Loki object backend | TLS | 90d hot, 1y cold | Daily snapshot |
| Application secrets | HashiCorp Vault | Transit + at-rest | Rotated quarterly | Vault snapshot daily |

### 1.8 GPU Node Pool Configuration

ML inference for the rPPG, perfusion, and risk engines requires GPU acceleration. The cluster provisions a dedicated GPU node pool:

- **Node size:** `g5.12xlarge` (4× NVIDIA A10G, 96 GiB GPU) or on-prem equivalent (4× A10 24 GB).
- **Taints:** `nvidia.com/gpu=NoSchedule` — only GPU-aware pods schedule.
- **Labels:** `accelerator=nvidia-a10g`, `workload-class=ml-inference`.
- **Daemonset:** NVIDIA Device Plugin + DCGM Exporter feed GPU metrics into Prometheus.
- **Cost discipline:** Cluster Autoscaler scales pool 1–4 nodes based on `risk_engine_pending_inference_depth`.

### 1.9 Cluster Topology — ASCII Diagram

```
                           ┌────────────────────────────────────────────┐
                           │              Internet / Hospital LAN       │
                           └───────────────┬────────────────────────────┘
                                           │ HTTPS (TLS 1.3, HSTS)
                                  ┌────────▼─────────┐
                                  │  NGINX Ingress   │  cert-manager (Let's Encrypt
                                  │  Controller       │   + ACME http-01 / dns-01)
                                  └────────┬─────────┘
                                           │
                                  ┌────────▼─────────┐
                                  │   Kong API GW     │  AuthN (JWT/OIDC),
                                  │  + WAF + rate-lim │  OWASP CRS, mTLS to svc
                                  └────────┬─────────┘
                                           │
        ┌──────────────────────────────────┼──────────────────────────────────┐
        │                                  │                                  │
┌───────▼──────────┐            ┌──────────▼─────────┐              ┌─────────▼─────────┐
│ denguesense-dev   │            │ denguesense-staging │              │ denguesense-prod  │
│  (G0–G4)          │            │   (G5–G7)           │              │   (G7–G8)         │
│                  │            │                    │              │                   │
│ capture-svc      │            │  ... mirror ...    │              │ risk-engine  ×3   │
│ risk-engine ×1   │            │                    │              │ capture-svc  ×2   │
│ ... 10 svcs      │            │                    │              │ clinical-svc ×2   │
│                  │            │                    │              │ ... (10 svcs)     │
└──────────────────┘            └────────────────────┘              └────────┬──────────┘
                                                                            │
                                          ┌─────────────────────────────────┼──────┐
                                          │                                 │      │
                                  ┌───────▼────────┐         ┌────────────▼─┐  ┌──▼──────────┐
                                  │ GPU node pool  │         │ Clinical DB  │  │ Audit log DB│
                                  │ 4× A10G, CUDA  │         │ PostgreSQL 16 │  │ PostgreSQL  │
                                  │ nvidia device  │         │ (TDE, PITR)   │  │ append-only │
                                  │ plugin + DCGM  │         └───────────────┘  └─────────────┘
                                  └────────────────┘
                                          │
                                  ┌───────▼────────────┐
                                  │ Observability plane │  Prometheus, Grafana,
                                  │ (separate namespace)│  Loki, Tempo, Sentry
                                  └─────────────────────┘
                                          │
                                  ┌───────▼────────────┐
                                  │ Object storage     │  MinIO (on-prem) or S3
                                  │ raw video + models  │  (cross-region replication)
                                  └─────────────────────┘
```

---

## 2. CI/CD Pipelines

### 2.1 Pipeline Architecture and Tooling

DengueSense uses GitHub Actions as primary CI/CD (GitLab CI fallback for on-prem hospital environments blocking GitHub). Pipeline definitions live in `.github/workflows/`; secrets are stored in GitHub Actions encrypted secrets and synced to HashiCorp Vault. The pipeline has nine stages in strict order: 1–6 mandatory on every PR; 7–9 on every merge to `main`. Each stage maps to a DengueSense gate (§2.3).

### 2.2 Testing Matrix (Adapted from Vibe Coding §10)

| Test Layer | Scope | Tool | Coverage / Pass Criteria | Frequency | Owning Gate |
|---|---|---|---|---|---|
| Unit | Functions, components, utilities | pytest + pytest-cov / Vitest | ≥ 80% line coverage | Every commit | G1 |
| Integration | API, DB, service-to-service contracts | Supertest, httpx + testcontainers | All critical paths pass | Every PR | G1 |
| E2E | scan → score → review workflows | Playwright | All Must Have stories pass | Every sprint | G4 |
| Visual regression | UI consistency across dashboard views | Chromatic | No visual diff on components | Every PR | G1 |
| Performance | Latency, throughput, inference time | k6 + Lighthouse CI | p95 < 500 ms, LH ≥ 90, inf < 2000 ms | Weekly / pre-launch | G7 |
| Security — deps | CVEs in dependencies | Snyk + pip-audit + npm audit | Zero high/critical | Every sprint | G3 |
| Security — API | OWASP Top 10 dynamic scan | OWASP ZAP baseline + full | Zero high/critical | Every sprint | G3 |
| Security — containers | Image vulnerabilities | Trivy (OS + lib + IaC) | Zero high/critical, max 5 medium | Every build | G3 |
| Security — secrets | Hard-coded secrets in history | gitleaks | Zero findings | Every commit | G1 |
| Clinical data leakage | Patient-level splits, predictor timestamps | Custom pytest leakage-audit suite | 100% rules pass | Pre-model-lock | G5 |
| Model performance | AUROC, calibration, sensitivity | MLflow + TRIPOD-CLI reporter | Meets SAP pre-registered thresholds | Pre-deployment | G6/G7 |

### 2.3 Stage-Gate to CI/CD Mapping

This mapping is the core mechanism by which CI/CD enforces the DengueSense delivery framework. A pipeline run cannot promote an artifact past a stage-gate boundary without the corresponding gate evidence recorded by the Technical Design Authority or Programme Director.

| DengueSense Gate | Programme Meaning | CI/CD Stage That Enforces It | Required Evidence Artifact |
|---|---|---|---|
| G0 — Charter approved | Charter, intended use, endpoints, TPP signed off | Manual `workflow_dispatch` to create dev namespace | Charter PDF hash |
| G1 — Usability 90%, zero critical security issues | Capture app + workflow tested | `usability-tests` + `security-scan` jobs | Usability report (signed), Snyk/ZAP clean |
| G2 — Analytical validation | Reference-device agreement per protocol | `analytical-validation` job | MLflow run with locked thresholds |
| G3 — Ethics & regulatory, site initiation | NMRR/MREC approvals in hand | `pre-deploy-staging` manual gate | NMRR ID in release notes |
| G4 — Recruitment & usable-signal rates | Real-patient data flowing in dev/staging | `recruitment-health-check` cron job | Recruitment dashboard screenshot |
| G5 — Clinical baseline + leakage audit + model card | Locked model ready for external validation | `model-lock` job uploads model card | Model card PDF, threshold record |
| G6 — External validation at independent site | Locked-site passes prespecified criteria | `external-validation` job on frozen test set | TRIPOD+AI report, PROBAST+AI review |
| G7 — Prospective silent validation + human factors | Real-time non-interventional validation passes | `shadow-deploy` + `canary-deploy` jobs | Shadow report, human-factors review |
| G8 — MDA pathway + submission-grade evidence | Regulatory submission-ready | `pre-deploy-prod` two-person manual gate | MDA correspondence, evidence dossier |

### 2.4 CI/CD Pipeline YAML (Complete)

```yaml
# .github/workflows/ci-cd.yml
name: DengueSense CI/CD
on:
  push:
    branches: [main, release/*]
  pull_request:
    branches: [main]
  workflow_dispatch:
    inputs:
      target_environment:
        description: Target namespace
        type: choice
        options: [denguesense-dev, denguesense-staging, denguesense-prod]
        default: denguesense-dev
      skip_gates:
        description: Comma-separated gate IDs to skip (emergency only)
        required: false
        default: ""

concurrency:
  group: ci-${{ github.ref }}-${{ inputs.target_environment || 'dev' }}
  cancel-in-progress: false
permissions: { contents: read, packages: write, id-token: write }
env:
  REGISTRY: ghcr.io/reainmaker/denguesense

jobs:
  lint:
    runs-on: ubuntu-22.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-python@v5
        with: { python-version: "3.11.9", cache: pip }
      - uses: actions/setup-node@v4
        with: { node-version: "20.17.0", cache: npm }
      - run: pip install ruff==0.6.9 mypy==1.11.2 && npm ci
      - run: ruff check . && ruff format --check . && mypy src --strict
      - run: npm run lint && npm run typecheck

  unit-test:
    needs: lint
    runs-on: ubuntu-22.04
    timeout-minutes: 20
    services:
      postgres:
        image: postgres:16.4-alpine
        env: { POSTGRES_PASSWORD: test }
        ports: ["5432:5432"]
        options: --health-cmd pg_isready --health-interval 5s --health-timeout 5s --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11.9", cache: pip }
      - run: pip install uv && uv sync --frozen
      - run: uv run pytest tests/unit -ra --cov=src --cov-fail-under=80 --cov-report=xml
      - uses: codecov/codecov-action@v4
        with: { token: ${{ secrets.CODECOV_TOKEN }}, files: ./coverage.xml }

  build:
    needs: unit-test
    runs-on: ubuntu-22.04
    timeout-minutes: 30
    permissions: { contents: read, packages: write, id-token: write }
    strategy:
      matrix:
        service: [capture-svc, sqi-engine, rppg-engine, perfusion-engine, ocular-engine, tongue-engine, optical-haem-engine, clinical-svc, risk-engine, dashboard]
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with: { registry: ghcr.io, username: ${{ github.actor }}, password: ${{ secrets.GITHUB_TOKEN }} }
      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ matrix.service }}
          tags: |
            type=sha,prefix=sha-,format=short
            type=semver,pattern={{version}}
            type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}
      - uses: docker/build-push-action@v6
        with: { context: ./services/${{ matrix.service }}, push: true, tags: ${{ steps.meta.outputs.tags }}, labels: ${{ steps.meta.outputs.labels }}, provenance: true, sbom: true, cache-from: type=gha, cache-to: "type=gha,mode=max" }

  security-scan:
    needs: build
    runs-on: ubuntu-22.04
    timeout-minutes: 25
    strategy: { matrix: { scan: [snyk-deps, zap-api, trivy-image, gitleaks] } }
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - if: matrix.scan == 'snyk-deps'
        uses: snyk/actions/python@master
        env: { SNYK_TOKEN: ${{ secrets.SNYK_TOKEN } }
        with: { command: monitor, args: "--severity-threshold=high --fail-on=upgradable" }
      - if: matrix.scan == 'zap-api'
        uses: zaproxy/action-baseline@v0.13.0
        with: { target: "https://risk-engine.denguesense-dev.svc.cluster.local", cmd_options: "-a -j" }
      - if: matrix.scan == 'trivy-image'
        uses: aquasecurity/trivy-action@master
        with: { image-ref: "${{ env.REGISTRY }}/risk-engine:latest", severity: "HIGH,CRITICAL", exit-code: 1 }
      - if: matrix.scan == 'gitleaks'
        uses: gitleaks/gitleaks-action@v2
        env: { GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN } }

  integration-test:
    needs: security-scan
    runs-on: ubuntu-22.04
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11.9", cache: pip }
      - run: docker compose -f docker-compose.test.yml up -d --wait
      - run: uv run pytest tests/integration -ra --maxfail=5
      - if: always()
        run: docker compose -f docker-compose.test.yml down -v

  deploy-staging:
    needs: integration-test
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-22.04
    environment:
      name: staging
      url: https://staging.denguesense.reainmaker.my
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - uses: azure/setup-kubectl@v4
      - uses: azure/login@v2
        with: { creds: ${{ secrets.AZURE_STAGING_CREDS } }
      - run: kubectl --context denguesense-staging apply -f k8s/staging/ --prune
      - run: kubectl --context denguesense-staging rollout status deploy/risk-engine -n denguesense-staging --timeout=300s

  smoke-test:
    needs: deploy-staging
    runs-on: ubuntu-22.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - run: pip install httpx==0.27.2 && python tests/smoke/smoke_suite.py --base-url https://staging.denguesense.reainmaker.my
      - run: npm install -g @lhci/cli@0.13.x && lhci autorun --config=.lighthouserc.staging.json

  manual-approval-prod:
    needs: smoke-test
    if: startsWith(github.ref, 'refs/heads/release/')
    runs-on: ubuntu-22.04
    environment: { name: production-approval, url: https://denguesense.reainmaker.my }
    timeout-minutes: 1440  # up to 24 h for sign-off
    steps:
      - name: Verify G8 sign-off
        run: |
          curl -fsS -X POST https://governance.reainmaker.my/api/gates/verify \
            -H "Authorization: Bearer ${{ secrets.GOV_API_TOKEN }}" \
            -d release="${{ github.ref_name }}" -d gate=G8
      - run: echo "G8 verified — proceeding to prod deploy"

  deploy-prod:
    needs: manual-approval-prod
    runs-on: ubuntu-22.04
    environment: { name: production, url: https://denguesense.reainmaker.my }
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - run: ./scripts/blue-green-deploy.sh risk-engine denguesense-prod
      - run: ./scripts/post-deploy-verify.sh https://denguesense.reainmaker.my
```

### 2.5 Blue-Green Deployment Strategy

Production deploys use blue-green for zero-downtime updates. Two replica sets — `risk-engine-blue` and `risk-engine-green` — coexist behind a weighted service. The script: (1) identifies the inactive colour; (2) applies the new Deployment with new image digest; (3) waits for `/ready` 200 on all pods; (4) runs a synthetic transaction suite against the new colour; (5) switches the Service selector atomically; (6) scales previous to 0 but keeps it 24 hours (rollback target); (7) emits an audit-log entry `deployment.switchover` with old/new digests, SLO snapshot, operator identity. Rollback reverses step 5; < 90 s.

### 2.6 Model Deployment Pipeline

Model changes follow a stricter pipeline than code changes — a model can pass every software test yet be clinically unsafe. The flow operationalises the DengueSense §10 ten-step sequence (lock endpoints → analytical validity → leakage audit → clinical baseline → incremental value → model lock → internal test → external validation → prospective silent validation).

```
 ┌────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
 │ 1. Train   │──▶│ 2. Validate  │──▶│ 3. Register  │──▶│ 4. Shadow    │
 │  (offline) │   │   (locked    │   │   (MLflow    │   │   deploy     │
 │  MLflow    │   │   test set)  │   │   + digest)  │   │   (G7)       │
 │  tracking  │   │   SAP        │   │   model card │   │   5% traffic │
 └────────────┘   │   thresholds │   │   + SHA256   │   └──────┬───────┘
                  └──────────────┘   └──────────────┘          │
                                                                 ▼
                  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
                  │ 7. Full      │◀──│ 6. Canary    │◀──│ 5. Review    │
                  │    rollout   │   │   25% traffic│   │   shadow     │
                  │   (G8)       │   │   48 h       │   │   metrics +  │
                  │   100%       │   │   SLO check  │   │   human      │
                  └──────────────┘   └──────────────┘   │   factors    │
                                                       └──────────────┘
```

- **Shadow deployment.** New model receives live traffic copies but its outputs are not returned to clinicians; logged alongside the production model for offline comparison.
- **Canary deployment.** 25% of live traffic routes to the new model for 48 hours; automated false-alert and alert-rate delta checks trigger rollback if either exceeds SAP tolerance.
- **Model version pinning.** Risk Engine reads `RISK_MODEL_VERSION` (ConfigMap pointer to an MLflow digest); changing it requires fresh G7 review + two-person GitOps PR.
- **Automated rollback triggers.** Error rate > 1% / 5 min, p95 > 1000 ms, output drift KS-stat > 0.1, or false-alert rate > 150% of locked baseline.

### 2.7 Release Protocol and Versioning

DengueSense follows semantic versioning with a regulatory suffix: `MAJOR.MINOR.PATCH-STATUS.BUILD` (e.g., `2026.8.0-RC.3`). Status tokens: `dev`, `rc`, `ga`, `hotfix`. A release is `ga` only after G8 sign-off; before that, every dashboard view shows a "Research Use Only — Not for clinical decision-making" banner. Each release ships with: (1) a CHANGELOG.md entry (Added/Changed/Fixed/Deprecated/Removed/Security, tagged to stage-gate); (2) a regulatory delta for changes since last `ga`; (3) a model card bundle (one PDF per locked model) with training summary, subgroup performance, calibration plot, intended use, limitations; (4) a signed SBOM (CycloneDX) from `syft`.

### 2.8 Rollback Procedures

Two rollback tiers exist. **Code rollback** triggers on a failed `/ready` probe after rollout, smoke-test failure, or manual operator action; executed by re-pointing the Service selector to the previous colour (< 90 s) and audit-logged. **Model rollback** triggers on SAP metric breach during canary or a clinical safety signal from the Data and Safety Monitoring function; executed by ConfigMap rollback to the previous model digest and a rolling restart of Risk Engine pods (< 5 min, dominated by model load time). Both paths are rehearsed quarterly via chaos-engineering that injects a broken release into `denguesense-staging` and measures time-to-rollback.

### 2.9 CI/CD Flow — ASCII Diagram

```
 ┌────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐     ┌──────────┐
 │  Push  │────▶│  Lint   │────▶│  Unit   │────▶│  Build  │────▶│ Security │
 │  / PR  │     │ ruff/   │     │  Test   │     │ 10 imgs │     │  Scan ×4 │
 │        │     │ mypy/   │     │  ≥80%   │     │  SBOM   │     │  zero H/C│
 │        │     │ eslint  │     │  cov    │     │  proven │     │          │
 └────────┘     └─────────┘     └─────────┘     └─────────┘     └────┬─────┘
                                                                     │
                                          ┌──────────────────────────▼┐
                                          │   Integration Test         │
                                          │   (testcontainers +       │
                                          │    service-to-service)    │
                                          └──────────────┬────────────┘
                                                         │  (only on push to main)
                                          ┌──────────────▼────────────┐
                                          │   Deploy → staging        │
                                          │   (G3 verified)           │
                                          └──────────────┬────────────┘
                                                         │
                                          ┌──────────────▼────────────┐
                                          │   Smoke Test + Lighthouse │
                                          │   p95<500 ms, LH ≥ 90     │
                                          └──────────────┬────────────┘
                                                         │
                                          ┌──────────────▼────────────┐
                                          │   Manual Approval (G8)    │
                                          │   Two-person + API verify │
                                          └──────────────┬────────────┘
                                                         │
                                          ┌──────────────▼────────────┐
                                          │   Blue-Green Deploy prod  │
                                          │   + post-deploy verify    │
                                          └──────────────┬────────────┘
                                                         │
                                          ┌──────────────▼────────────┐
                                          │   Audit Log Entry +       │
                                          │   24 h watch (auto        │
                                          │   rollback on SLO breach) │
                                          └───────────────────────────┘
```

---

## 3. Monitoring & Logging

### 3.1 Observability Stack

The observability stack deploys into a dedicated `observability` namespace, shared across environments: **Prometheus** (metrics, 15-day retention); **Grafana** (operational/clinical/compliance dashboards); **Loki** (structured logs + Promtail DaemonSet); **Tempo** (distributed tracing via OTel SDKs); **Sentry** (error tracking + release health); **Alertmanager** (routing, dedup, PagerDuty on-call); **OTel Collector** (gateway to Prometheus/Loki/Tempo).

### 3.2 Health-Check Endpoints

Every service exposes three standard endpoints. An OPA Gatekeeper policy refuses any Deployment missing a liveness probe to `/health`.

| Endpoint | Purpose | Response | Cache-Control |
|---|---|---|---|
| `GET /health` | Liveness — process alive and able to serve? | `200 {"status":"alive"}` if serving; `503` otherwise. No dependency checks. | `no-store` |
| `GET /ready` | Readiness — ready for production traffic? | `200` only if all critical deps (DB, model registry, downstream) respond < 500 ms. | `no-store` |
| `GET /metrics` | Prometheus scrape target. Exposes RED metrics + app gauges (e.g. `risk_engine_inference_seconds`). | Text/plain Prometheus exposition. | `no-store` |

### 3.3 Alert Thresholds

Alerts are defined in Prometheus Rule files, grouped by severity. The thresholds below are the authoritative baseline; tighter per-environment thresholds may be applied via ConfigMap overlay.

| Metric | Warning Threshold | Critical Threshold | Default Action |
|---|---|---|---|
| API latency p95 | > 500 ms / 5 min | > 1000 ms / 2 min | Page on-call; auto-scale; critical → Clinical Steering |
| Error rate (5xx) | > 1% / 5 min | > 5% / 2 min | Page on-call; critical triggers rollback eval |
| Signal-quality rejection | > 30% / 15 min | > 50% / 5 min | Notify Capture owner; page Clinical Steering if persistent |
| Model inference time | > 1500 ms / 5 min | > 2000 ms / 2 min | Page ML platform; evaluate rollback |
| Disk usage | > 80% | > 90% | Slack → page; auto `kubectl prune` |
| GPU memory | > 85% / 10 min | > 95% / 2 min | Page ML platform; scale GPU pool |
| Audit log write failure | n/a | any failure | Page Clinical Steering + Privacy Officer |
| Model output drift (KS) | > 0.08 / 24 h | > 0.1 / 6 h | Freeze promotion; page Clinical Steering |
| Certificate expiry | < 21 days | < 7 days | Slack → page; auto-renew via cert-manager |
| Backup job failure | n/a | any failure | Page DBA; re-run < 1 h; escalate if 2x consecutive |

### 3.4 Structured Logging Standard

All services emit JSON Lines logs with a fixed schema enforced by a shared `denguesense-logging` library. Entries without `trace_id` are rejected at the OTel Collector.

| Field | Type | Required | Notes |
|---|---|---|---|
| `timestamp` | ISO 8601 tz | yes | UTC |
| `level` | enum | yes | DEBUG–CRITICAL |
| `service` | string | yes | From container metadata |
| `trace_id` | W3C | yes | Via `traceparent` header |
| `request_id` | UUID v7 | yes | Assigned at ingress |
| `user_id` | SHA-256 | when applicable | Hashed identity |
| `module` | string | yes | e.g. `risk-engine.inference` |
| `action` | string | yes | Operation verb |
| `outcome` | enum | yes | success/failure/partial/denied |
| `duration_ms` | integer | when applicable | Operation duration |
| `error.*` | string | on failure | Standardised taxonomy |
| `meta` | object | optional | No PHI |

Example:
```json
{"timestamp":"2026-08-14T03:21:09.118Z","level":"INFO","service":"risk-engine","trace_id":"00-4bf92f...","request_id":"0191a3f2-...","user_id":"sha256:9f86d...","module":"risk-engine.inference","action":"score","outcome":"success","duration_ms":1240,"meta":{"model_version":"2026.08.0","risk_band":"moderate"}}
```

### 3.5 Clinical Audit Logging (Separate from Operational Logs)

Operational logs answer "is the system healthy?"; clinical audit logs answer "who saw what data, what decision was made, when, and on what evidence?". The two are physically and cryptographically separated. The clinical audit log is a separate PostgreSQL cluster with a single append-only table; UPDATE/DELETE are refused and every row carries `prev_row_hash` + `row_hash` forming a tamper-evident hash chain.

```sql
CREATE TABLE clinical_audit_log (
    id              BIGSERIAL PRIMARY KEY,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    event_type      TEXT NOT NULL CHECK (event_type IN
                      ('data_access','model_decision','clinician_action',
                       'config_change','export','auth','print')),
    actor_id_hash   CHAR(64) NOT NULL,    -- SHA-256 of identity
    actor_role      TEXT NOT NULL,
    patient_pseudonym TEXT NOT NULL,      -- never MRN
    resource_type   TEXT NOT NULL,
    resource_id     TEXT NOT NULL,
    model_version   TEXT,                 -- when model_decision
    risk_band       TEXT,                 -- when applicable
    inputs_hash     CHAR(64),             -- SHA-256 of inputs
    outputs_hash    CHAR(64),             -- SHA-256 of outputs
    outcome         TEXT NOT NULL,
    justification   TEXT,
    prev_row_hash   CHAR(64) NOT NULL,    -- hash of previous row
    row_hash        CHAR(64) NOT NULL     -- SHA-256 of preceding cols
);
REVOKE UPDATE, DELETE ON clinical_audit_log FROM PUBLIC;
CREATE RULE no_update AS ON UPDATE TO clinical_audit_log DO INSTEAD NOTHING;
CREATE RULE no_delete AS ON DELETE TO clinical_audit_log DO INSTEAD NOTHING;
```

A daily job recomputes the hash chain and emits a P1 alert on mismatch — the integrity guarantee MDA, MREC, and ISO 13485 auditors inspect. Audit entries are written **before** the response returns to the clinician, on the same transaction as the clinical-decision insert, so no decision can be silently lost. The audit log also satisfies traceability expectations of IEC 62304 (software lifecycle), ISO 14971 (medical-device risk management), and IEC 81001-5-1 (health-software security); access patterns feed the ISO/IEC 27001 information-security management system.

### 3.6 Dashboard Design

Three dashboard groups ship as Grafana JSON-as-code:

1. **Operational (DevOps).** Request rate, p50/p95/p99 latency, error-budget burn-down, pod restarts, GPU utilisation, DB pool saturation, deploy frequency, MTTR. Audience: SRE.
2. **Clinical.** Scans/day, signal-quality rejection by subgroup (sex, age, skin-tone), risk-band distribution, alert rate per patient-day, false-alert rate vs baseline, model output drift. Audience: Clinical Steering, Clinical PI.
3. **Compliance.** Data-access by actor, data exports, audit-log integrity, failed auths, cert expiry, backup success. Audience: Privacy & Security Review body, Regulatory/Quality leads, external auditors.

Dashboards are reviewed at every stage gate and re-baselined when a new risk enters the RAID log.

### 3.7 Post-Deployment Verification Checklist

Adapted from Vibe Coding §11.5 and extended for the clinical context. The on-call SRE checks every item within 30 minutes of a production switchover.

| # | Check | Pass Criterion | Owner |
|---|---|---|---|
| 1 | HTTPS active with padlock | TLS 1.3; cert > 60 days; HSTS present | SRE |
| 2 | SSL Labs grade | A or A+ | SRE |
| 3 | Lighthouse score | ≥ 90 on dashboard | Frontend |
| 4 | Critical workflow tested live | Scan → score → review (synthetic patient) | QA |
| 5 | Health & ready probes green | 100% of pods ready | SRE |
| 6 | Prometheus scraping | Zero targets down | SRE |
| 7 | Grafana dashboards render | All three groups load with fresh data | SRE |
| 8 | Sentry release health | New release marked `healthy` | SRE |
| 9 | Alertmanager routes verified | Test alert reaches on-call < 60 s | SRE |
| 10 | Audit log integrity check | Hash chain zero mismatches | Privacy Officer |
| 11 | Backup job post-deploy | Snapshot verified; PITR WAL current | DBA |
| 12 | Model version pinned | ConfigMap matches release notes | ML Platform |
| 13 | Clinical Steering notified | Ack recorded in governance system | Programme Director |

### 3.8 Backup Strategy and Recovery

The backup strategy operationalises Vibe Coding §4.2's non-functional requirement ("automated backups every 6 hours, RTO under 4 hours"). For a clinical system, cadence is tightened and objectives split by data class.

| Data Class | Backup Cadence | Retention | Recovery Objective | Tested |
|---|---|---|---|---|
| Clinical PostgreSQL (operational) | Continuous WAL + daily full snapshot | 7 years | RPO < 5 min, RTO < 1 h | Monthly drill |
| Clinical audit log (PostgreSQL) | Continuous WAL + hourly snapshot | 10 years | RPO < 1 min, RTO < 30 min | Monthly + integrity re-verify |
| Object storage (raw video) | Cross-region replication + daily snapshot | 7 years | RPO < 15 min, RTO < 4 h | Quarterly |
| Model artifacts | Daily snapshot + MLflow lineage | Permanent | RPO < 24 h, RTO < 2 h | Quarterly |
| Vault secrets | Daily snapshot + shamir-sealed backup | Permanent | RPO < 24 h, RTO < 2 h | Quarterly |
| Configuration (GitOps) | Continuous (Git source of truth) | Permanent | RPO < 0 (declarative) | Quarterly rebuild |

**Restore (PostgreSQL):** (1) provision a fresh PostgreSQL in an isolated namespace; (2) restore the most recent snapshot via `pgBackrest restore`; (3) replay WAL forward to the target timestamp (`recovery_target_time`); (4) run audit-log hash-chain verification, alert on mismatch; (5) run alembic schema check, alert if down-migration required; (6) mark restored cluster read-only, notify Privacy Officer. The full procedure is rehearsed quarterly in a non-production environment; outcome is recorded in the compliance dashboard. A failed rehearsal is a P1 incident blocking the next production release.

