import { randomBytes } from 'node:crypto';
import Fastify, { type FastifyError, type FastifyInstance, type FastifyReply, type FastifyRequest } from 'fastify';
import { serializerCompiler, validatorCompiler } from 'fastify-type-provider-zod';
import { ZodError } from 'zod';
import { ApiError } from './errors';
import type { AppDeps } from './deps';
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

export function buildApp(deps: AppDeps): FastifyInstance {
  const app = Fastify({
    logger: false,
    genReqId: (req) => traceIdOf(req.headers.traceparent) ?? randomBytes(16).toString('hex'),
  });
  app.decorate('deps', deps);
  app.decorateRequest('actor', null); // set by the auth guards in ./auth
  app.setValidatorCompiler(validatorCompiler);
  app.setSerializerCompiler(serializerCompiler);

  app.addHook('onRequest', async (req, reply) => {
    reply.header('X-Request-Id', req.id);
  });

  app.setNotFoundHandler((req, reply) =>
    reply.status(404).send(envelope(req, deps.now, 'DS_NOT_FOUND_001', 'Route not found')),
  );

  app.setErrorHandler((err: FastifyError | ApiError | ZodError, req: FastifyRequest, reply: FastifyReply) => {
    if (err instanceof ApiError) {
      return reply.status(err.status).send(envelope(req, deps.now, err.code, err.message, err.detail ?? {}));
    }
    const fe = err as FastifyError;
    if (err instanceof ZodError || fe.validation || fe.statusCode === 400) {
      const issues = err instanceof ZodError ? err.issues : (fe.validation ?? []);
      return reply
        .status(400)
        .send(envelope(req, deps.now, 'DS_VALIDATION_001', 'Request validation failed', { issues }));
    }
    req.log.error(err);
    return reply.status(500).send(envelope(req, deps.now, 'DS_INTERNAL_001', 'Internal server error'));
  });

  app.get('/health', async () => ({ status: 'alive' }));

  return app;
}

declare module 'fastify' {
  interface FastifyInstance {
    deps: AppDeps;
  }
}
