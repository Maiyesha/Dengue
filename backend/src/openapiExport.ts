// Builds the OpenAPI document from the real route registrations (no database needed: handlers
// are never invoked, so dependency stubs suffice).
import { buildApp } from './app';
import type { AppDeps } from './deps';

export async function generateOpenApi(): Promise<Record<string, unknown>> {
  const app = buildApp({ now: () => new Date(0) } as unknown as AppDeps);
  try {
    await app.ready();
    return JSON.parse(JSON.stringify(app.swagger())) as Record<string, unknown>;
  } finally {
    await app.close();
  }
}
