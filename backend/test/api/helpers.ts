// Shared API test helpers: RS256 test keypair, token minting, and buildTestApp() with fakes.
import { randomUUID } from 'node:crypto';
import { SignJWT, generateKeyPair, jwtVerify } from 'jose';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../../src/app';
import type { AppDeps, DeviceClaims, DeviceTokenSigner } from '../../src/deps';
import { getTestPool } from '../pg';
import { FakeAppAttest, FakeObjectStore, FakePush, FakeQualityQueue, FakeWebauthn } from './fakes';

export const TEST_ISSUER = 'https://idp.test.denguesense';
export const DEVICE_AUDIENCE = 'device-upload';

/** User-JWT RS256 keypair (the IdP's key). */
export const userKeys = await generateKeyPair('RS256');
/** Separate keypair for device tokens (server-issued after App Attest). */
const deviceKeys = await generateKeyPair('RS256');

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

/** Test DeviceTokenSigner: RS256, aud "device-upload", 24 h. */
export const deviceTokenSigner: DeviceTokenSigner = {
  async sign(c: DeviceClaims): Promise<string> {
    return new SignJWT({ device_id: c.device_id, site_id: c.site_id })
      .setProtectedHeader({ alg: 'RS256' })
      .setIssuer(TEST_ISSUER)
      .setAudience(DEVICE_AUDIENCE)
      .setSubject(c.device_id)
      .setJti(randomUUID())
      .setIssuedAt()
      .setExpirationTime('24h')
      .sign(deviceKeys.privateKey);
  },
  async verify(t: string): Promise<DeviceClaims> {
    const { payload } = await jwtVerify(t, deviceKeys.publicKey, {
      issuer: TEST_ISSUER,
      audience: DEVICE_AUDIENCE,
      algorithms: ['RS256'],
      requiredClaims: ['exp'],
    });
    if (typeof payload.device_id !== 'string' || typeof payload.site_id !== 'string') {
      throw new Error('device token missing claims');
    }
    return { device_id: payload.device_id, site_id: payload.site_id };
  },
};

export function deviceTokenFor(deviceId: string, siteId: string): Promise<string> {
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
