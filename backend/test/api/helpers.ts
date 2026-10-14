// Shared API test helpers: RS256 test keypair, token minting, and buildTestApp() with fakes.
import { randomUUID } from 'node:crypto';
import { SignJWT, generateKeyPair } from 'jose';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../../src/app';
import type { AppDeps, DeviceTokenSigner } from '../../src/deps';
import { DEVICE_TOKEN_ALG, JoseDeviceTokenSigner } from '../../src/deviceToken';
import { getTestPool } from '../pg';
import { FakeAppAttest, FakeObjectStore, FakePush, FakeQualityQueue, FakeWebauthn } from './fakes';

export const TEST_ISSUER = 'https://idp.test.denguesense';
export const DEVICE_AUDIENCE = 'device-upload';

/** User-JWT RS256 keypair (the IdP's key). */
export const userKeys = await generateKeyPair('RS256');
/** Separate keypair for device tokens (server-issued after App Attest). */
const deviceKeys = await generateKeyPair(DEVICE_TOKEN_ALG);

export interface TokenOpts {
  sub?: string;
  deidentify?: boolean;
  /** Seconds relative to now for exp (default +900 = 15 min). */
  expiresIn?: number;
  /** Seconds relative to now for iat (default 0). */
  issuedAt?: number;
  issuer?: string;
  extraRoles?: string[];
  key?: CryptoKey;
  audience?: string;
}

const nowSec = () => Math.floor(Date.now() / 1000);

/** Mints an access JWT for one role (sub defaults to the fixture user id `rls-<role>`). */
export async function tokenFor(role: string, siteId?: string, o: TokenOpts = {}): Promise<string> {
  const t = nowSec();
  const claims: Record<string, unknown> = {
    roles: [role, ...(o.extraRoles ?? [])],
    deidentify: o.deidentify ?? false,
  };
  if (siteId !== undefined) claims.site_id = siteId;
  const jwt = new SignJWT(claims)
    .setProtectedHeader({ alg: 'RS256' })
    .setSubject(o.sub ?? `rls-${role}`)
    .setIssuer(o.issuer ?? TEST_ISSUER)
    .setJti(randomUUID())
    .setIssuedAt(t + (o.issuedAt ?? 0))
    .setExpirationTime(t + (o.expiresIn ?? 900));
  if (o.audience) jwt.setAudience(o.audience);
  return jwt.sign(o.key ?? userKeys.privateKey);
}

export const DEVICE_TOKEN_ISSUER = 'https://api.test.denguesense/devices';

/** The production signer with a test ES256 key (distinct from the RS256 user key). */
export const deviceTokenSigner: DeviceTokenSigner = new JoseDeviceTokenSigner({
  privateKey: deviceKeys.privateKey,
  publicKey: deviceKeys.publicKey,
  issuer: DEVICE_TOKEN_ISSUER,
});

/** Ward used for devices auto-enrolled by deviceTokenFor(). */
export const testDeviceWard = (siteId: string) => `devw-${siteId}`;

/**
 * Mints a device token. Device auth checks the devices row on every request, so this first
 * ensures an active device row exists (superuser insert; clearFixtures removes it).
 */
export async function deviceTokenFor(deviceId: string, siteId: string): Promise<string> {
  const pool = getTestPool();
  await pool.query('INSERT INTO wards(id, site_id) VALUES ($1,$2) ON CONFLICT DO NOTHING', [testDeviceWard(siteId), siteId]);
  await pool.query('INSERT INTO devices(id, site_id, ward_id) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING',
    [deviceId, siteId, testDeviceWard(siteId)]);
  return deviceTokenSigner.sign({ device_id: deviceId, site_id: siteId });
}

export interface TestFakes {
  objectStore: FakeObjectStore;
  qualityQueue: FakeQualityQueue;
  appAttest: FakeAppAttest;
  webauthn: FakeWebauthn;
  push: FakePush;
}

export interface TestApp {
  app: FastifyInstance;
  deps: AppDeps;
  fakes: TestFakes;
}

/**
 * Builds the app against the migrated test DB with fakes for every external dependency.
 * `register` runs before ready(), so tests can add test-only routes.
 */
export async function buildTestApp(
  register?: (app: FastifyInstance) => void,
  overrides: Partial<AppDeps> = {},
): Promise<TestApp> {
  const fakes: TestFakes = {
    objectStore: new FakeObjectStore(),
    qualityQueue: new FakeQualityQueue(),
    appAttest: new FakeAppAttest(),
    webauthn: new FakeWebauthn(),
    push: new FakePush(),
  };
  const deps: AppDeps = {
    pool: getTestPool(),
    jwtVerifyKey: userKeys.publicKey,
    jwtIssuer: TEST_ISSUER,
    deviceTokenSigner,
    now: () => new Date(),
    ...fakes,
    ...overrides,
  };
  const app = buildApp(deps);
  register?.(app);
  await app.ready();
  return { app, deps, fakes };
}

export const bearer = (token: string) => ({ authorization: `Bearer ${token}` });
