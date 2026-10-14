// Production device-token signer (server-issued after a successful App Attest assertion).
//
// - alg pinned to ES256 (ECDSA P-256). The user access JWT is RS256 from the IdP, so the device
//   key is necessarily a different key (different key type); a user key can never verify, or be
//   confused with, a device token.
// - iss pinned (constructor), aud "device-upload", sub = device_id, jti, iat, exp = iat + 24 h.
// - verify enforces alg, iss, aud, exp, and maxTokenAge 24 h (iat), plus sub == device_id.
import { randomUUID } from 'node:crypto';
import { SignJWT, jwtVerify } from 'jose';
import type { DeviceClaims, DeviceTokenSigner, KeyLike } from './deps';
import { DEVICE_AUDIENCE } from './auth';

export const DEVICE_TOKEN_ALG = 'ES256';
export const DEVICE_TOKEN_TTL_SEC = 86400;

export interface JoseDeviceTokenSignerOptions {
  /** ES256 private key. Must NOT be the user-JWT key (it cannot be: the user key is RSA). */
  privateKey: KeyLike;
  publicKey: KeyLike;
  /** Pinned issuer, e.g. "https://api.denguesense.my/devices". */
  issuer: string;
  now?: () => Date;
}

const nonEmpty = (v: unknown): v is string => typeof v === 'string' && v.length > 0;

export class JoseDeviceTokenSigner implements DeviceTokenSigner {
  private readonly now: () => Date;

  constructor(private readonly o: JoseDeviceTokenSignerOptions) {
    if (!nonEmpty(o.issuer)) throw new Error('JoseDeviceTokenSigner: issuer is required');
    this.now = o.now ?? (() => new Date());
  }

  async sign(c: DeviceClaims): Promise<string> {
    if (!nonEmpty(c.device_id) || !nonEmpty(c.site_id)) throw new Error('device token claims must be non-empty');
    const iat = Math.floor(this.now().getTime() / 1000);
    return new SignJWT({ device_id: c.device_id, site_id: c.site_id })
      .setProtectedHeader({ alg: DEVICE_TOKEN_ALG, typ: 'JWT' })
      .setIssuer(this.o.issuer)
      .setAudience(DEVICE_AUDIENCE)
      .setSubject(c.device_id)
      .setJti(randomUUID())
      .setIssuedAt(iat)
      .setExpirationTime(iat + DEVICE_TOKEN_TTL_SEC)
      .sign(this.o.privateKey);
  }

  async verify(t: string): Promise<DeviceClaims> {
    const { payload } = await jwtVerify(t, this.o.publicKey, {
      algorithms: [DEVICE_TOKEN_ALG],
      issuer: this.o.issuer,
      audience: DEVICE_AUDIENCE,
      currentDate: this.now(),
      maxTokenAge: DEVICE_TOKEN_TTL_SEC,
      requiredClaims: ['sub', 'exp', 'iat', 'jti'],
    });
    if (!nonEmpty(payload.device_id) || !nonEmpty(payload.site_id) || payload.sub !== payload.device_id) {
      throw new Error('device token claims invalid');
    }
    return { device_id: payload.device_id, site_id: payload.site_id };
  }
}
