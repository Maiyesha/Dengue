// Response-contract assertions: every success response is checked against the R.* zod schema that
// ROUTE_DOCS (src/openapi.ts) publishes for that route and status, so the OpenAPI document the iOS
// client codes against cannot drift from what the handlers really return.
import { expect } from 'vitest';
import { ROUTE_DOCS } from '../../src/openapi';

interface Res {
  statusCode: number;
  body: string;
  json: () => unknown;
}

/** "METHOD /openapi/path STATUS" combinations validated so far (per test file). */
export const contractCovered = new Set<string>();

/**
 * Asserts that `res` is a documented success response of `method path` (OpenAPI path syntax,
 * e.g. '/v1/scans/{id}') and that its body parses with the documented schema WITHOUT any
 * undocumented fields. 204/no-content routes must return an empty body. Returns `res`.
 */
export function expectContract<T extends Res>(res: T, method: string, path: string): T {
  const key = `${method.toUpperCase()} ${path}`;
  const doc = ROUTE_DOCS[key];
  expect(doc, `${key} is not in ROUTE_DOCS`).toBeDefined();
  const schema = doc.ok[res.statusCode];
  expect(schema, `${key} returned undocumented status ${res.statusCode}: ${res.body}`).not.toBeUndefined();
  if (schema === null) {
    expect(res.body, `${key} ${res.statusCode} must have no body`).toBe('');
  } else {
    const body = res.json();
    const parsed = schema.safeParse(body);
    expect(parsed.success, `${key} ${res.statusCode} violates its schema: ${JSON.stringify(parsed.error?.issues)}`).toBe(true);
    // zod objects strip unknown keys: a difference means the handler returned undocumented fields.
    expect(parsed.data, `${key} ${res.statusCode} returned undocumented fields`).toEqual(body);
  }
  contractCovered.add(`${key} ${res.statusCode}`);
  return res;
}

/** Every documented "METHOD path STATUS" success combination. */
export const allDocumentedSuccesses = (): string[] =>
  Object.entries(ROUTE_DOCS).flatMap(([k, d]) => Object.keys(d.ok).map((s) => `${k} ${s}`));
