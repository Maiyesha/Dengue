// OpenAPI 3.1 contract for /v1. The iOS client codes against the exported file
// (contracts/openapi-v1.json).
//
// Request shapes (params, query, body) come straight from each route's zod schema via
// @fastify/swagger + fastify-type-provider-zod's jsonSchemaTransform: the route schema is the
// single source. Routes deliberately declare no `response` schema (that would turn on output
// validation and change behaviour), so responses, security and the Idempotency-Key header are
// layered on here from ROUTE_DOCS, keyed by "METHOD /openapi/path". The document build fails if a
// registered route has no entry, so new routes cannot ship undocumented.
import { z } from 'zod';
import { jsonSchemaTransform } from 'fastify-type-provider-zod';
import type { SwaggerOptions } from '@fastify/swagger';
import { LAB_UNITS, VITAL_UNITS } from './units';

// ---------------------------------------------------------------------------------------------
// Error catalog
// ---------------------------------------------------------------------------------------------
export interface ErrorCatalogEntry {
  code: string;
  http_status: number;
  meaning: string;
}

export const ERROR_CATALOG: readonly ErrorCatalogEntry[] = [
  { code: 'DS_AUD_001', http_status: 403, meaning: 'The audit record could not be written, so the whole operation was rolled back.' },
  { code: 'DS_AUD_002', http_status: 500, meaning: 'Database-level guard: the audit trigger requires READ COMMITTED isolation. A server defect if it ever surfaces; reported as DS_INTERNAL_001.' },
  { code: 'DS_AUTH_001', http_status: 401, meaning: 'Credentials missing, malformed, invalid or expired.' },
  { code: 'DS_AUTH_002', http_status: 403, meaning: 'Valid credentials, but the token kind or role is not allowed on this route (including a device token on a user-only route).' },
  { code: 'DS_AUTH_003', http_status: 401, meaning: 'Clinician review step-up failed: the review challenge is unknown, expired, already used, issued to someone else or bound to a different scan/action/reason_code/note, or the WebAuthn assertion over it could not be verified. Challenges are single use (spent even on failure): request a new one.' },
  { code: 'DS_CLINICAL_001', http_status: 409, meaning: 'An observation_id or lab id is already in use for a different patient.' },
  { code: 'DS_DEVICE_001', http_status: 401, meaning: 'The device is not enrolled or has been revoked.' },
  { code: 'DS_DEVICE_002', http_status: 401, meaning: 'The App Attest assertion counter did not strictly increase (replay).' },
  { code: 'DS_DEVICE_003', http_status: 401, meaning: 'The challenge is unknown, expired, already used, or was not issued to the caller.' },
  { code: 'DS_DEVICE_004', http_status: 401, meaning: 'App Attest attestation or assertion verification failed.' },
  { code: 'DS_DEVICE_005', http_status: 409, meaning: 'This App Attest key_id is already enrolled.' },
  { code: 'DS_IDEMPOTENCY_001', http_status: 409, meaning: 'The Idempotency-Key was already used with a different request payload.' },
  { code: 'DS_IDEMPOTENCY_002', http_status: 400, meaning: 'The Idempotency-Key header (UUID v4) is missing or malformed.' },
  { code: 'DS_IDEMPOTENCY_003', http_status: 409, meaning: 'A request with this Idempotency-Key is still in progress; retry later.' },
  { code: 'DS_INTERNAL_001', http_status: 500, meaning: 'Unexpected server error. The response carries no internal detail.' },
  { code: 'DS_NOT_FOUND', http_status: 404, meaning: 'No such route, or the resource does not exist or is not visible to the caller (access denial on a resource is reported as 404, never 403).' },
  { code: 'DS_QG_000', http_status: 422, meaning: 'The scan has not passed the quality gate (status is not quality_passed).' },
  { code: 'DS_QG_099', http_status: 422, meaning: 'Maximum recaptures reached for a step; the step is marked UNABLE_TO_ACQUIRE. detail lists unable_to_acquire, recaptured and the new scan status.' },
  { code: 'DS_RATE_001', http_status: 429, meaning: 'Too many outstanding renewal challenges for this device.' },
  { code: 'DS_REG_001', http_status: 451, meaning: 'Regulatory hold: no valid primary-research consent (none recorded, withdrawn, or not primary research).' },
  { code: 'DS_REG_002', http_status: 451, meaning: 'The patient consented to a superseded consent version; re-consent is required.' },
  { code: 'DS_SCAN_001', http_status: 409, meaning: 'Another non-revoked scan for this patient was captured within 30 minutes of captured_at.' },
  { code: 'DS_SCAN_002', http_status: 409, meaning: 'client_session_id is already used for a different scan.' },
  { code: 'DS_STATE_001', http_status: 409, meaning: 'The scan status does not allow this operation (illegal transition).' },
  { code: 'DS_STATE_002', http_status: 500, meaning: 'Database-level guard: an immutable scan column was changed. A server defect if it ever surfaces; reported as DS_INTERNAL_001.' },
  { code: 'DS_STATE_003', http_status: 500, meaning: 'Database-level guard: the acting role lacks authority for the scan transition. Reported as DS_INTERNAL_001 if it ever surfaces.' },
  { code: 'DS_UPLOAD_001', http_status: 422, meaning: 'The uploaded object sha256 does not match the declared value; the artefact is marked rejected.' },
  { code: 'DS_UPLOAD_002', http_status: 422, meaning: 'No such step attempt exists for this scan.' },
  { code: 'DS_UPLOAD_003', http_status: 409, meaning: 'The artefact was already declared with a different sha256.' },
  { code: 'DS_UPLOAD_004', http_status: 409, meaning: 'The artefact status does not accept upload parts.' },
  { code: 'DS_UPLOAD_005', http_status: 409, meaning: 'The upload is incomplete: the uploaded parts add up to fewer bytes than size_bytes (detail: received_bytes, size_bytes). Retryable: upload the missing parts and complete again (the same Idempotency-Key may be reused). The artefact status is unchanged.' },
  { code: 'DS_VALIDATION_001', http_status: 400, meaning: 'Request validation failed (unknown field, wrong type, out of range, wrong unit, unsupported media type, malformed JSON). detail.issues lists the problems.' },
  { code: 'DS_VALIDATION_002', http_status: 413, meaning: 'Request payload too large (body over the server limit, 1 MiB).' },
];

const ErrorCodeSchema = z.enum(ERROR_CATALOG.map((e) => e.code) as [string, ...string[]]);
const ErrorEnvelopeSchema = z
  .object({
    error: z.object({
      code: ErrorCodeSchema,
      message: z.string(),
      detail: z.record(z.string(), z.unknown()),
      request_id: z.string(),
      trace_id: z.string(),
      timestamp: z.string().datetime(),
    }),
  })
  .strict();

// ---------------------------------------------------------------------------------------------
// Response schemas (mirror what each handler returns)
// ---------------------------------------------------------------------------------------------
const ScanStatus = z.enum([
  'capture_pending', 'quality_pending', 'quality_passed', 'quality_failed', 'feature_pending', 'feature_complete',
  'acquisition_failure', 'partial', 'review_pending', 'reviewed', 'flagged', 'excluded', 'archived', 'revoked',
]);
const Consent = z.object({
  primary_research: z.boolean(),
  consent_version: z.string(),
  current_version: z.string(),
  withdrawn: z.boolean(),
  capture_allowed: z.boolean().describe('Same rule as the capture gate: true only when block_code is null'),
  block_code: z.enum(['DS_REG_001', 'DS_REG_002']).nullable().describe('451 code a capture would get now; null when capture is allowed'),
  checked_at: z.string().datetime(),
});
const ScanView = z.object({
  id: z.string().uuid(),
  status: ScanStatus,
  steps: z.array(
    z.object({
      step: z.string(),
      attempt: z.number().int(),
      device_verdict: z.enum(['ACCEPT', 'RECAPTURE', 'UNABLE_TO_ACQUIRE']),
      server_verdict: z.string().nullable(),
      reason_codes: z.array(z.string()),
    }),
  ),
  recaptures_remaining: z.record(z.string(), z.number().int()),
});

const R = {
  Health: z.object({ status: z.literal('alive') }),
  PatientLookup: z.object({
    patient_id: z.string().uuid(),
    participant_code: z.string(),
    bed_label: z.string().nullable(),
    ward_id: z.string().nullable(),
    last_captured_at: z.string().datetime().nullable(),
  }),
  Roster: z.object({
    items: z.array(
      z.object({
        patient_id: z.string().uuid(),
        participant_code: z.string(),
        bed_label: z.string().nullable(),
        consent: Consent,
      }),
    ),
    generated_at: z.string().datetime(),
  }),
  Consent,
  ClinicalData: z.object({
    accepted: z.number().int(),
    duplicates: z.number().int(),
    invalid: z.array(z.string().uuid()).describe('observation_ids stored but flagged INVALID (out of physiological range)'),
  }),
  ScanCreated: z.object({
    scan: z.object({ id: z.string().uuid(), status: ScanStatus, client_session_id: z.string().uuid() }),
  }),
  ScanRead: z.object({ scan: ScanView }),
  ArtefactDeclared: z.object({ artefact_id: z.string().uuid(), upload_id: z.string().nullable() }),
  PartUrl: z.object({ url: z.string(), expires_in: z.literal(900) }),
  ArtefactComplete: z.object({ status: z.literal('received_verified') }),
  FeatureExtract: z.object({ scan_id: z.string().uuid(), status: z.literal('extraction_accepted') }),
  ReviewChallenge: z.object({
    challenge_id: z.string().uuid(),
    challenge: z.string().describe('32 random bytes, base64url (no padding); the WebAuthn challenge to sign'),
    expires_in: z.literal(300),
  }),
  Review: z.object({
    review_id: z.string().uuid(),
    scan_id: z.string().uuid(),
    status: z.enum(['reviewed', 'flagged', 'excluded']),
    push: z.enum(['sent', 'failed', 'skipped']),
  }),
  Experimental: z.object({
    enabled: z.boolean(),
    items: z.array(
      z.object({
        domain: z.enum(['rppg_face', 'rppg_fingertip']),
        pulse_rate_bpm: z.number().int(),
        label: z.literal('EXPERIMENTAL'),
        notice: z.string(),
      }),
    ),
  }),
  Challenge: z.object({ challenge: z.string().describe('32 random bytes, standard base64') }),
  DeviceEnrolled: z.object({ device_id: z.string().uuid() }),
  DeviceToken: z.object({ device_token: z.string(), expires_in: z.literal(86400) }),
};

// ---------------------------------------------------------------------------------------------
// Per-route documentation
// ---------------------------------------------------------------------------------------------
type Auth = 'none' | 'user' | 'device' | 'user_or_device' | 'optional_user';
interface RouteDoc {
  operationId: string;
  summary: string;
  tag: string;
  auth: Auth;
  /** User roles that may call the route (device tokens are described by `auth`). */
  roles?: string[];
  idempotent?: boolean;
  /** Success status -> response schema (null = no content). */
  ok: Record<number, z.ZodType | null>;
  /** Error statuses beyond the generic ones derived from `auth` / `idempotent`. */
  errors?: number[];
  /** Extra OpenAPI operation fields (e.g. x-units). */
  extensions?: Record<string, unknown>;
}

const SITE = ['nurse_operator', 'clinician'];

export const ROUTE_DOCS: Record<string, RouteDoc> = {
  'GET /health': { operationId: 'getHealth', summary: 'Liveness probe', tag: 'system', auth: 'none', ok: { 200: R.Health } },
  'GET /v1/patients/lookup': {
    operationId: 'lookupPatient', summary: 'Find a patient by participant code', tag: 'patients', auth: 'user', roles: SITE,
    ok: { 200: R.PatientLookup }, errors: [400, 404],
  },
  'GET /v1/wards/{wardId}/roster': {
    operationId: 'getWardRoster', summary: 'Ward roster with consent status', tag: 'patients', auth: 'user', roles: SITE,
    ok: { 200: R.Roster }, errors: [400, 404],
  },
  'GET /v1/patients/{id}/consent-status': {
    operationId: 'getConsentStatus', summary: 'Current consent status of a patient', tag: 'patients', auth: 'user', roles: SITE,
    ok: { 200: R.Consent }, errors: [400, 404],
  },
  'POST /v1/patients/{id}/clinical-data': {
    operationId: 'submitClinicalData', summary: 'Submit reference vitals and labs (idempotent per id)', tag: 'clinical', auth: 'user', roles: SITE,
    idempotent: true, ok: { 201: R.ClinicalData }, errors: [404],
    extensions: { 'x-units': { vitals: VITAL_UNITS, labs: LAB_UNITS } },
  },
  'POST /v1/scans': {
    operationId: 'createScan', summary: 'Create a scan session (201 new, 200 if client_session_id already stored)', tag: 'scans', auth: 'user', roles: SITE,
    idempotent: true, ok: { 200: R.ScanCreated, 201: R.ScanCreated }, errors: [404, 451],
  },
  'GET /v1/scans/{id}': {
    operationId: 'getScan', summary: 'Read a scan with per-step attempts and recaptures remaining', tag: 'scans', auth: 'user_or_device', roles: SITE,
    ok: { 200: R.ScanRead }, errors: [400, 404],
  },
  'POST /v1/scans/{id}/recapture': {
    operationId: 'recaptureScanSteps', summary: 'Request recapture of steps (max 3 attempts per step)', tag: 'scans', auth: 'user', roles: SITE,
    idempotent: true, ok: { 200: R.ScanRead }, errors: [404, 422, 451],
  },
  'POST /v1/scans/{id}/artefacts': {
    operationId: 'declareArtefact', summary: 'Declare an artefact and open a multipart upload (201 new, 200 if already declared)', tag: 'artefacts', auth: 'user_or_device', roles: SITE,
    idempotent: true, ok: { 200: R.ArtefactDeclared, 201: R.ArtefactDeclared }, errors: [404, 422, 451],
  },
  'POST /v1/artefacts/{id}/parts/{n}/url': {
    operationId: 'getArtefactPartUrl', summary: 'Pre-signed URL for one upload part (valid 900 s; no Idempotency-Key, every call returns a fresh URL)', tag: 'artefacts', auth: 'user_or_device', roles: SITE,
    ok: { 200: R.PartUrl }, errors: [400, 404, 409],
  },
  'POST /v1/artefacts/{id}/complete': {
    operationId: 'completeArtefact', summary: 'Complete the upload and verify sha256; may trigger the quality gate', tag: 'artefacts', auth: 'user_or_device', roles: SITE,
    idempotent: true, ok: { 200: R.ArtefactComplete }, errors: [404, 422, 451],
  },
  'POST /v1/scans/{id}/features/extract': {
    operationId: 'extractFeatures', summary: 'Request feature extraction (system agent; scan must be quality_passed)', tag: 'scans', auth: 'user', roles: ['system_agent'],
    idempotent: true, ok: { 202: R.FeatureExtract }, errors: [404, 422],
  },
  'POST /v1/scans/{id}/review-challenge': {
    operationId: 'createReviewChallenge', summary: 'Issue a single-use WebAuthn challenge bound to a review (5 min; no Idempotency-Key)', tag: 'review', auth: 'user', roles: ['clinician'],
    ok: { 200: R.ReviewChallenge }, errors: [400, 404, 409],
  },
  'POST /v1/scans/{id}/review': {
    operationId: 'reviewScan', summary: 'Clinician review with WebAuthn step-up over a server-issued challenge (challenge_id)', tag: 'review', auth: 'user', roles: ['clinician'],
    idempotent: true, ok: { 201: R.Review }, errors: [404],
  },
  'GET /v1/scans/{id}/experimental': {
    operationId: 'getExperimentalView', summary: 'Gated experimental pulse-rate view (not validated for care decisions)', tag: 'review', auth: 'user', roles: SITE,
    ok: { 200: R.Experimental }, errors: [400, 404],
  },
  'POST /v1/devices/challenge': {
    operationId: 'createDeviceChallenge', summary: 'Issue an App Attest enrolment challenge', tag: 'devices', auth: 'user', roles: ['admin', 'clinician'],
    idempotent: true, ok: { 200: R.Challenge },
  },
  'POST /v1/devices/attest': {
    operationId: 'attestDevice', summary: 'Enrol a device from an App Attest attestation', tag: 'devices', auth: 'user', roles: ['admin', 'clinician'],
    idempotent: true, ok: { 201: R.DeviceEnrolled }, errors: [404],
  },
  'POST /v1/devices/{id}/renewal-challenge': {
    operationId: 'createRenewalChallenge', summary: 'Issue a token-renewal challenge for an active device (no authentication)', tag: 'devices', auth: 'none',
    ok: { 200: R.Challenge }, errors: [400, 404, 429],
  },
  'POST /v1/devices/assert': {
    operationId: 'assertDevice', summary: 'Exchange an App Attest assertion for a 24 h device token', tag: 'devices', auth: 'optional_user', roles: ['admin', 'clinician'],
    ok: { 200: R.DeviceToken }, errors: [400, 404],
  },
  'POST /v1/devices/push-token': {
    operationId: 'registerPushToken', summary: 'Register the APNs push token of the calling device', tag: 'devices', auth: 'device',
    idempotent: true, ok: { 204: null }, errors: [404],
  },
};

const ERROR_STATUS_TEXT: Record<number, string> = {
  400: 'Validation failed (DS_VALIDATION_001) or Idempotency-Key missing (DS_IDEMPOTENCY_002)',
  401: 'Unauthenticated (DS_AUTH_001), device/assertion failure (DS_DEVICE_001..004), or review step-up failure (DS_AUTH_003)',
  403: 'Role or token kind not allowed (DS_AUTH_002) or audit failure (DS_AUD_001)',
  404: 'Not found or not visible to the caller (DS_NOT_FOUND)',
  409: 'Conflict (DS_IDEMPOTENCY_001/003, DS_SCAN_001/002, DS_STATE_001, DS_UPLOAD_003/004/005, DS_CLINICAL_001, DS_DEVICE_005)',
  422: 'Unprocessable (DS_QG_000, DS_QG_099, DS_UPLOAD_001/002)',
  429: 'Rate limited (DS_RATE_001)',
  413: 'Request payload too large (DS_VALIDATION_002)',
  451: 'Consent gate (DS_REG_001 / DS_REG_002)',
  500: 'Internal error (DS_INTERNAL_001)',
};

const SECURITY: Record<Auth, Array<Record<string, string[]>>> = {
  none: [],
  user: [{ userBearer: [] }],
  device: [{ deviceBearer: [] }],
  user_or_device: [{ userBearer: [] }, { deviceBearer: [] }],
  optional_user: [{}, { userBearer: [] }],
};

// ---------------------------------------------------------------------------------------------
// Document assembly
// ---------------------------------------------------------------------------------------------
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

/** Zod -> OpenAPI 3.1 schema (draft 2020-12 without the $schema marker). */
function js(schema: z.ZodType): Json {
  const out = z.toJSONSchema(schema, { target: 'draft-2020-12', io: 'output', unrepresentable: 'any' }) as Json;
  delete out.$schema;
  return out;
}

const ref = (name: string) => ({ $ref: `#/components/schemas/${name}` });

/** Recursively sorts object keys so serialisation is deterministic. Arrays keep their order. */
export function sortKeys<T>(v: T): T {
  if (Array.isArray(v)) return v.map(sortKeys) as unknown as T;
  if (v && typeof v === 'object') {
    return Object.fromEntries(
      Object.keys(v as object)
        .sort()
        .map((k) => [k, sortKeys((v as Json)[k])]),
    ) as T;
  }
  return v;
}

export const stringifyContract = (doc: unknown) => `${JSON.stringify(sortKeys(doc), null, 2)}\n`;

/** Point error.code at the shared ErrorCode schema instead of repeating the enum. */
function withCodeRef(envelope: Json): Json {
  envelope.properties.error.properties.code = ref('ErrorCode');
  return envelope;
}

function decorate(doc: Json): Json {
  const used = new Set<string>();
  for (const [path, item] of Object.entries<Json>(doc.paths ?? {})) {
    for (const [method, op] of Object.entries<Json>(item)) {
      const key = `${method.toUpperCase()} ${path}`;
      const d = ROUTE_DOCS[key];
      if (!d) throw new Error(`OpenAPI: route ${key} has no entry in ROUTE_DOCS`);
      used.add(key);

      op.operationId = d.operationId;
      op.summary = d.summary;
      op.tags = [d.tag];
      op.security = SECURITY[d.auth];
      if (d.roles) op['x-roles'] = d.roles;
      op['x-auth'] = d.auth;
      Object.assign(op, d.extensions ?? {});
      if (d.auth === 'optional_user') {
        op.description =
          'Authentication is optional. With a user bearer token (admin or clinician with a site): enrolment flow, challenge issued by POST /v1/devices/challenge. ' +
          'Without a token: renewal flow, challenge issued by POST /v1/devices/{id}/renewal-challenge; the App Attest assertion is the credential. An invalid token is 401, never a fall-through to renewal. ' +
          'Exempt from Idempotency-Key: the response is a live bearer credential and is never stored.';
      } else if (d.auth === 'none' && d.tag === 'devices') {
        op.description = 'No authentication. Exempt from Idempotency-Key. Unknown or revoked devices are 404.';
      }

      const params: Json[] = (op.parameters ?? []).filter(
        (p: Json) => p.in !== 'header' || String(p.name).toLowerCase() !== 'idempotency-key',
      );
      if (d.idempotent) params.push({ $ref: '#/components/parameters/IdempotencyKey' });
      if (params.length) op.parameters = params;
      else delete op.parameters;

      const responses: Json = {};
      for (const [status, schema] of Object.entries(d.ok)) {
        responses[status] = schema
          ? { description: 'Success', content: { 'application/json': { schema: js(schema) } } }
          : { description: 'Success (no content)' };
      }
      const errs = new Set<number>(d.errors ?? []);
      if (d.auth !== 'none') {
        errs.add(401);
        errs.add(403);
      }
      if (method === 'post') errs.add(413);
      if (d.idempotent) {
        errs.add(400);
        errs.add(409);
      }
      errs.add(500);
      for (const s of [...errs].sort((a, b) => a - b)) {
        responses[String(s)] = {
          description: ERROR_STATUS_TEXT[s] ?? 'Error',
          content: { 'application/json': { schema: ref('ErrorEnvelope') } },
        };
      }
      op.responses = responses;
    }
  }
  for (const k of Object.keys(ROUTE_DOCS)) {
    if (!used.has(k)) throw new Error(`OpenAPI: ROUTE_DOCS entry ${k} matches no registered route`);
  }

  doc.components = {
    ...(doc.components ?? {}),
    securitySchemes: {
      userBearer: {
        type: 'http',
        scheme: 'bearer',
        bearerFormat: 'JWT',
        description: 'User access JWT (RS256, 15 min). Claims: sub, roles, site_id, deidentify, jti.',
      },
      deviceBearer: {
        type: 'http',
        scheme: 'bearer',
        bearerFormat: 'JWT',
        description:
          'Device token (aud "device-upload", claims device_id and site_id, 24 h). Callable only on artefact routes, GET /v1/scans/{id} and POST /v1/devices/push-token.',
      },
    },
    parameters: {
      IdempotencyKey: {
        name: 'Idempotency-Key',
        in: 'header',
        required: true,
        schema: { type: 'string', format: 'uuid' },
        description:
          'UUID v4. Same key and payload replays the stored response; same key with a different payload is 409 DS_IDEMPOTENCY_001. Kept 24 h.',
      },
    },
    schemas: {
      ...(doc.components?.schemas ?? {}),
      ErrorCode: { ...js(ErrorCodeSchema), description: 'Stable machine-readable error code; clients dispatch on this.' },
      ErrorEnvelope: withCodeRef(js(ErrorEnvelopeSchema)),
    },
  };
  doc['x-error-catalog'] = ERROR_CATALOG.map((e) => ({ ...e }));
  doc.tags = [...new Set(Object.values(ROUTE_DOCS).map((d) => d.tag))].sort().map((name) => ({ name }));
  return doc;
}

/** @fastify/swagger options; request schemas come from the routes' zod schemas. */
export const swaggerOptions: SwaggerOptions = {
  openapi: {
    openapi: '3.1.0',
    info: {
      title: 'DengueSense API',
      version: '1.0.0',
      description:
        'Phase A contact-free capture API. All routes are under /v1; errors use the envelope {error:{code,message,detail,request_id,trace_id,timestamp}}.',
    },
  },
  transform: jsonSchemaTransform,
  transformObject: (o) => decorate((o as { openapiObject: Json }).openapiObject) as never,
};
