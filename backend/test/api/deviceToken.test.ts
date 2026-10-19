import { randomUUID } from 'node:crypto';
import { describe, it, expect } from 'vitest';
import { SignJWT, decodeJwt, decodeProtectedHeader, generateKeyPair } from 'jose';
import { JoseDeviceTokenSigner, DEVICE_TOKEN_ALG, DEVICE_TOKEN_TTL_SEC } from '../../src/deviceToken';

const ISS = 'https://api.test.denguesense/devices';
const keys = await generateKeyPair(DEVICE_TOKEN_ALG);
const DEV = randomUUID();

function signer(now: () => Date = () => new Date()) {
  return new JoseDeviceTokenSigner({ privateKey: keys.privateKey, publicKey: keys.publicKey, issuer: ISS, now });
}

/** A token with the signer's key but hand-chosen claims/header (for negative tests). */
async function forge(o: {
  alg?: string; key?: CryptoKey | Uint8Array; iss?: string; aud?: string; iat?: number; exp?: number;
  claims?: Record<string, unknown>;
}) {
  const t = Math.floor(Date.now() / 1000);
  return new SignJWT(o.claims ?? { device_id: DEV, site_id: 'S1' })
    .setProtectedHeader({ alg: o.alg ?? DEVICE_TOKEN_ALG })
    .setIssuer(o.iss ?? ISS)
    .setAudience(o.aud ?? 'device-upload')
    .setSubject(DEV)
    .setJti(randomUUID())
    .setIssuedAt(o.iat ?? t)
    .setExpirationTime(o.exp ?? t + 3600)
    .sign(o.key ?? keys.privateKey);
}

describe('JoseDeviceTokenSigner', () => {
  it('signs ES256, pinned issuer, aud device-upload, 24 h TTL; verify round-trips', async () => {
    const s = signer();
    const t = await s.sign({ device_id: DEV, site_id: 'S1' });
    expect(decodeProtectedHeader(t).alg).toBe('ES256');
    const p = decodeJwt(t);
    expect(p.iss).toBe(ISS);
    expect(p.aud).toBe('device-upload');
    expect(p.sub).toBe(DEV);
    expect(typeof p.jti).toBe('string');
    expect(p.exp! - p.iat!).toBe(86400);
    expect(DEVICE_TOKEN_TTL_SEC).toBe(86400);
    expect(await s.verify(t)).toEqual({ device_id: DEV, site_id: 'S1' });
  });

  it('expired token rejected (clock moved past 24 h)', async () => {
    const t = await signer().sign({ device_id: DEV, site_id: 'S1' });
    const later = signer(() => new Date(Date.now() + 86401 * 1000));
    await expect(later.verify(t)).rejects.toThrow();
  });

  it('token older than 24 h (iat) rejected even if exp is later', async () => {
    const t0 = Math.floor(Date.now() / 1000);
    await expect(signer().verify(await forge({ iat: t0 - 90000, exp: t0 + 3600 }))).rejects.toThrow();
  });

  it('wrong issuer / wrong audience rejected', async () => {
    await expect(signer().verify(await forge({ iss: 'https://evil' }))).rejects.toThrow();
    await expect(signer().verify(await forge({ aud: 'something-else' }))).rejects.toThrow();
  });

  it('another key, another alg (RS256, HS256) rejected', async () => {
    const other = await generateKeyPair('ES256');
    await expect(signer().verify(await forge({ key: other.privateKey }))).rejects.toThrow();
    const rsa = await generateKeyPair('RS256');
    await expect(signer().verify(await forge({ alg: 'RS256', key: rsa.privateKey }))).rejects.toThrow();
    await expect(signer().verify(await forge({ alg: 'HS256', key: new Uint8Array(32) }))).rejects.toThrow();
  });

  it('alg none rejected', async () => {
    const t = await signer().sign({ device_id: DEV, site_id: 'S1' });
    const [, payload] = t.split('.');
    const none = `${Buffer.from(JSON.stringify({ alg: 'none' })).toString('base64url')}.${payload}.`;
    await expect(signer().verify(none)).rejects.toThrow();
  });

  it('missing / non-string device_id or site_id, or sub != device_id, rejected', async () => {
    await expect(signer().verify(await forge({ claims: { site_id: 'S1' } }))).rejects.toThrow();
    await expect(signer().verify(await forge({ claims: { device_id: DEV, site_id: 7 } }))).rejects.toThrow();
    await expect(signer().verify(await forge({ claims: { device_id: randomUUID(), site_id: 'S1' } }))).rejects.toThrow();
  });

  it('sign rejects empty claims', async () => {
    await expect(signer().sign({ device_id: '', site_id: 'S1' })).rejects.toThrow();
  });
});
