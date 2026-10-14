import { randomBytes } from 'node:crypto';
import Fastify, { type FastifyError, type FastifyInstance, type FastifyReply, type FastifyRequest } from 'fastify';
import { serializerCompiler, validatorCompiler } from 'fastify-type-provider-zod';
import swagger from '@fastify/swagger';
import { ZodError } from 'zod';
import { ApiError } from './errors';
import type { AppDeps } from './deps';
import { idempotencyPlugin } from './idempotency';
import { swaggerOptions } from './openapi';
import { artefactRoutes } from './routes/artefacts';
import { clinicalDataRoutes } from './routes/clinicalData';
import { patientRoutes } from './routes/patients';
import { reviewRoutes } from './routes/review';
import { deviceRoutes } from './routes/devices';
import { scanRoutes } from './routes/scans';
import './auth'; // FastifyRequest.actor type augmentation

const TRACEPARENT = /^[0-9a-f]{2}-([0-9a-f]{32})-[0-9a-f]{16}-[0-9a-f]{2}$/i;

function traceIdOf(header: unknown): string | undefined {
  if (typeof header !== 'string') return undefined;
  const m = TRACEPARENT.exec(header.trim());
  if (!m || /^0+$/.test(m[1])) return undefined;
  return m[1].toLowerCase();
}

function envelope(req: FastifyRequest, now: () => Date, code: string, message: string, detail: object = {}) {
  return {
    error: {
      code,
      message,
      detail,
      request_id: String(req.id),
      trace_id: traceIdOf(req.headers.traceparent) ?? String(req.id),
      timestamp: now().toISOString(),
    },
  };
}

export interface BuildOptions {
  /** pino level; default LOG_LEVEL or 'info'. Tests pass 'silent'. */
  logLevel?: string;
  /** Log destination (default stdout). */
  logStream?: { write(msg: string): void };
}

/**
 * Credentials never reach the logs (M3). `req.headers.*` covers any serializer that logs headers;
 * `request.headers.*` is the shape logged for unhandled errors below.
 */
export const LOG_REDACT_PATHS = [
  'req.headers.authorization',
  'req.headers.cookie',
  'request.headers.authorization',
  'request.headers.cookie',
];

export function buildApp(deps: AppDeps, opts: BuildOptions = {}): FastifyInstance {
  const app = Fastify({
    logger: {
      level: opts.logLevel ?? process.env.LOG_LEVEL ?? 'info',
      redact: { paths: LOG_REDACT_PATHS, censor: '[REDACTED]' },
      ...(opts.logStream ? { stream: opts.logStream } : {}),
    },
    genReqId: (req) => traceIdOf(req.headers.traceparent) ?? randomBytes(16).toString('hex'),
  });
  app.decorate('deps', deps);
  app.decorateRequest('actor', null); // set by the auth guards in ./auth
  app.setValidatorCompiler(validatorCompiler);
  app.setSerializerCompiler(serializerCompiler);

  // fastify-plugin (not encapsulated): must be registered before every route it documents.
  app.register(swagger, swaggerOptions);
  app.get('/openapi.json', { schema: { hide: true } }, async () => app.swagger());

  app.addHook('onRequest', async (req, reply) => {
    reply.header('X-Request-Id', req.id);
  });

  app.setNotFoundHandler((req, reply) =>
    reply.status(404).send(envelope(req, deps.now, 'DS_NOT_FOUND', 'Route not found')),
  );

  app.setErrorHandler((err: FastifyError | ApiError | ZodError, req: FastifyRequest, reply: FastifyReply) => {
    if (err instanceof ApiError) {
      return reply.status(err.status).send(envelope(req, deps.now, err.code, err.message, err.detail ?? {}));
    }
    const fe = err as FastifyError;
    // M2: Fastify's own client errors. 413 (body too large) keeps its status; every other 4xx
    // (415 media type, malformed JSON, ...) is a request validation failure.
    if (fe.statusCode === 413) {
      return reply.status(413).send(envelope(req, deps.now, 'DS_VALIDATION_002', 'Request payload too large'));
    }
    const clientError = typeof fe.statusCode === 'number' && fe.statusCode >= 400 && fe.statusCode < 500;
    if (err instanceof ZodError || fe.validation || clientError) {
      const issues = err instanceof ZodError ? err.issues : (fe.validation ?? (fe.code ? [{ code: fe.code, message: fe.message }] : []));
      return reply
        .status(400)
        .send(envelope(req, deps.now, 'DS_VALIDATION_001', 'Request validation failed', { issues }));
    }
    // M3: every 500 is logged with the request line and headers (credentials redacted).
    req.log.error({ err, request: { method: req.method, url: req.url, headers: req.headers } }, 'unhandled error');
    return reply.status(500).send(envelope(req, deps.now, 'DS_INTERNAL_001', 'Internal server error'));
  });

  // Registered as a plugin so it loads after swagger and is picked up by its onRoute hook.
  app.register(async (i) => {
    i.get('/health', async () => ({ status: 'alive' }));
  });

  // Not encapsulated: its hooks must see every route registered after it.
  app.register(idempotencyPlugin);
  app.register(patientRoutes);
  app.register(scanRoutes);
  app.register(artefactRoutes);
  app.register(clinicalDataRoutes);
  app.register(reviewRoutes);
  app.register(deviceRoutes);

  return app;
}

declare module 'fastify' {
  interface FastifyInstance {
    deps: AppDeps;
  }
}
