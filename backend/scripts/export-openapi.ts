// Writes the /v1 contract to <repo root>/contracts/openapi-v1.json (stable key order).
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { generateOpenApi } from '../src/openapiExport';
import { stringifyContract } from '../src/openapi';

const out = resolve(dirname(fileURLToPath(import.meta.url)), '../../contracts/openapi-v1.json');
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, stringifyContract(await generateOpenApi()));
console.log(`wrote ${out}`);
