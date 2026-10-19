// SimpleWebauthnVerifier adapter: challenge matching against the stored hash, and the
// updateCounter callback (F8). @simplewebauthn/server is mocked (no real authenticator).
import { createHash, randomBytes } from 'node:crypto';
import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('@simplewebauthn/server', () => ({ verifyAuthenticationResponse: vi.fn() }));
const { verifyAuthenticationResponse } = await import('@simplewebauthn/server');
const { SimpleWebauthnVerifier } = await import('../../src/webauthn');

const mocked = vi.mocked(verifyAuthenticationResponse);
const raw = randomBytes(32);
const hash = createHash('sha256').update(raw).digest('hex');
const credential = { id: 'cred-1', publicKey: new Uint8Array([1]), counter: 3 };

/** The mock calls the adapter's expectedChallenge with what clientDataJSON would carry. */
function authenticatorSigned(challenge: Buffer, newCounter = 7) {
  mocked.mockImplementation(async (opts: any) => {
    const ok = typeof opts.expectedChallenge === 'function'
      ? await opts.expectedChallenge(challenge.toString('base64url'))
      : opts.expectedChallenge === challenge.toString('base64url');
    if (!ok) throw new Error('Unexpected authentication response challenge');
    return { verified: true, authenticationInfo: { credentialID: 'cred-1', newCounter } } as any;
  });
}

describe('SimpleWebauthnVerifier', () => {
  let updates: Array<[string, number]>;
  let verifier: InstanceType<typeof SimpleWebauthnVerifier>;
  beforeEach(() => {
    updates = [];
    mocked.mockReset();
    verifier = new SimpleWebauthnVerifier({
      expectedOrigin: 'https://app.test',
      expectedRPID: 'app.test',
      lookupCredential: async (_u, id) => (id === 'cred-1' ? (credential as any) : null),
      updateCounter: async (id, n) => {
        updates.push([id, n]);
      },
    });
  });

  it('accepts an assertion over the server challenge whose sha256 matches, then stores the new counter', async () => {
    authenticatorSigned(raw, 9);
    expect(await verifier.verify('u1', { id: 'cred-1' }, hash)).toBe(true);
    expect(updates).toEqual([['cred-1', 9]]);
    expect(mocked.mock.calls[0][0]).toMatchObject({ credential, requireUserVerification: true });
  });

  it('rejects an assertion over a different challenge; no counter update', async () => {
    authenticatorSigned(randomBytes(32));
    expect(await verifier.verify('u1', { id: 'cred-1' }, hash)).toBe(false);
    expect(updates).toEqual([]);
  });

  it('unknown credential -> false without calling the library', async () => {
    expect(await verifier.verify('u1', { id: 'cred-x' }, hash)).toBe(false);
    expect(mocked).not.toHaveBeenCalled();
  });

  it('a failing counter store fails closed', async () => {
    authenticatorSigned(raw);
    const v = new SimpleWebauthnVerifier({
      expectedOrigin: 'https://app.test',
      expectedRPID: 'app.test',
      lookupCredential: async () => credential as any,
      updateCounter: async () => {
        throw new Error('db down');
      },
    });
    expect(await v.verify('u1', { id: 'cred-1' }, hash)).toBe(false);
  });
});
