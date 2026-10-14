import { describe, it, expect } from 'vitest';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import SwaggerParser from '@apidevtools/swagger-parser';
import { buildApp } from '../../src/app';
import type { AppDeps } from '../../src/deps';
import { ERROR_CATALOG, stringifyContract } from '../../src/openapi';
import { generateOpenApi } from '../../src/openapiExport';

const here = dirname(fileURLToPath(import.meta.url));
const srcDir = resolve(here, '../../src');
const committedPath = resolve(here, '../../../contracts/openapi-v1.json');

// Every route registered in Tasks 4-9 (plus /health), as "METHOD openapi-path".
const EXPECTED_ROUTES = [
  'GET /health',
  'GET /v1/patients/lookup',
  'GET /v1/wards/{wardId}/roster',
  'GET /v1/patients/{id}/consent-status',
  'POST /v1/patients/{id}/clinical-data',
  'POST /v1/scans',
  'GET /v1/scans/{id}',
  'POST /v1/scans/{id}/recapture',
  'POST /v1/scans/{id}/artefacts',
  'POST /v1/artefacts/{id}/parts/{n}/url',
  'POST /v1/artefacts/{id}/complete',
  'POST /v1/scans/{id}/features/extract',
  'POST /v1/scans/{id}/review',
  'GET /v1/scans/{id}/experimental',
  'POST /v1/devices/challenge',
  'POST /v1/devices/attest',
  'POST /v1/devices/{id}/renewal-challenge',
  'POST /v1/devices/assert',
  'POST /v1/devices/push-token',
];

function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? sourceFiles(p) : p.endsWith('.ts') ? [p] : [];
  });
}

describe('OpenAPI contract', () => {
  it('openapi validates with swagger-parser', async () => {
    const doc = await generateOpenApi();
    expect(doc.openapi).toBe('3.1.0');
    await expect(SwaggerParser.validate(structuredClone(doc) as never)).resolves.toBeTruthy();
    await expect(SwaggerParser.validate(committedPath)).resolves.toBeTruthy();
  });

  it('contains every route registered in Tasks 4-9, with security marked', async () => {
    const doc = (await generateOpenApi()) as { paths: Record<string, Record<string, { security: unknown[]; responses: object }>> };
    const got = Object.entries(doc.paths).flatMap(([p, i]) => Object.keys(i).map((m) => `${m.toUpperCase()} ${p}`));
    expect(got.sort()).toEqual([...EXPECTED_ROUTES].sort());
    const sec = (k: string) => {
      const [m, p] = k.split(' ');
      return doc.paths[p][m.toLowerCase()].security;
    };
    expect(sec('POST /v1/devices/{id}/renewal-challenge')).toEqual([]);
    expect(sec('POST /v1/scans')).toEqual([{ userBearer: [] }]);
    expect(sec('POST /v1/devices/push-token')).toEqual([{ deviceBearer: [] }]);
    expect(sec('POST /v1/artefacts/{id}/complete')).toEqual([{ userBearer: [] }, { deviceBearer: [] }]);
  });

  it('serves the same document at GET /openapi.json', async () => {
    const app = buildApp({ now: () => new Date(0) } as unknown as AppDeps);
    const res = await app.inject({ method: 'GET', url: '/openapi.json' });
    await app.close();
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual(JSON.parse(stringifyContract(await generateOpenApi())));
  });

  it('committed contracts/openapi-v1.json equals generated output', async () => {
    const committed = readFileSync(committedPath, 'utf8');
    expect(JSON.parse(committed)).toEqual(JSON.parse(stringifyContract(await generateOpenApi())));
  });

  it('error catalog covers every DS_ code in backend/src and matches the ErrorCode enum', async () => {
    const used = new Set<string>();
    for (const f of sourceFiles(srcDir)) {
      if (f.endsWith('openapi.ts')) continue; // the catalog itself
      for (const m of readFileSync(f, 'utf8').matchAll(/\bDS_(?:NOT_FOUND|[A-Z]+_[0-9]{3})\b/g)) used.add(m[0]);
    }
    expect(used.size).toBeGreaterThan(20);
    const catalog = new Set(ERROR_CATALOG.map((e) => e.code));
    expect([...used].filter((c) => !catalog.has(c))).toEqual([]);
    expect(catalog.size).toBe(ERROR_CATALOG.length);

    const doc = (await generateOpenApi()) as {
      components: { schemas: { ErrorCode: { enum: string[] } } };
      'x-error-catalog': Array<{ code: string; http_status: number; meaning: string }>;
    };
    expect([...doc.components.schemas.ErrorCode.enum].sort()).toEqual([...catalog].sort());
    expect(doc['x-error-catalog'].map((e) => e.code).sort()).toEqual([...catalog].sort());
    for (const e of doc['x-error-catalog']) {
      expect(e.http_status).toBeGreaterThanOrEqual(400);
      expect(e.meaning.length).toBeGreaterThan(5);
    }
  });
});
