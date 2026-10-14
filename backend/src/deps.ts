import type pg from 'pg';
import type { KeyObject } from 'node:crypto';

/** jose v6 dropped the KeyLike export; this is the equivalent accepted by jwtVerify. */
export type KeyLike = CryptoKey | KeyObject | Uint8Array;

export interface DeviceClaims {
  device_id: string;
  site_id: string;
}

export interface ObjectStore {
  createMultipart(key: string): Promise<string /* uploadId */>;
  presignPart(key: string, uploadId: string, partNumber: number, ttlSec: 900): Promise<string>;
  completeMultipart(key: string, uploadId: string): Promise<void>;
  sha256(key: string): Promise<string>;
}

export interface QualityQueue {
  enqueue(scanId: string): Promise<void>;
}

export interface AppAttestVerifier {
  verifyAttestation(keyId: string, attestationObject: Buffer, challenge: Buffer): Promise<{ publicKey: Buffer }>;
  verifyAssertion(
    publicKey: Buffer,
    assertion: Buffer,
    clientDataHash: Buffer,
    prevCounter: number,
  ): Promise<{ counter: number }>;
}

export interface AssertionVerifier {
  verify(userId: string, assertion: unknown, expectedChallengeHash: string): Promise<boolean>;
}

export interface PushSender {
  send(deviceId: string, payload: { type: string; scan_id?: string; [k: string]: unknown }): Promise<void>;
}

export interface DeviceTokenSigner {
  sign(c: DeviceClaims): Promise<string>;
  verify(t: string): Promise<DeviceClaims>;
}

export interface AppDeps {
  pool: pg.Pool;
  jwtVerifyKey: KeyLike;
  jwtIssuer: string;
  objectStore: ObjectStore;
  qualityQueue: QualityQueue;
  appAttest: AppAttestVerifier;
  webauthn: AssertionVerifier;
  push: PushSender;
  deviceTokenSigner: DeviceTokenSigner;
  now: () => Date;
}
