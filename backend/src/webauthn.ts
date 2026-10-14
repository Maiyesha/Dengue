// Real AssertionVerifier backed by @simplewebauthn/server. Unit-tested only through the fake
// (no real authenticator available); this class is a thin adapter.
import { verifyAuthenticationResponse, type WebAuthnCredential } from '@simplewebauthn/server';
import type { AssertionVerifier } from './deps';

export interface WebauthnConfig {
  expectedOrigin: string | string[];
  expectedRPID: string | string[];
  /** Registered credential for the user matching the assertion's credential id; null if unknown. */
  lookupCredential(userId: string, credentialId: string): Promise<WebAuthnCredential | null>;
}

export class SimpleWebauthnVerifier implements AssertionVerifier {
  constructor(private readonly cfg: WebauthnConfig) {}

  /**
   * The challenge signed by the authenticator is the UTF-8 bytes of `expectedChallengeHash`
   * (sha256 hex of the canonical review payload); clientDataJSON carries it base64url-encoded.
   */
  async verify(userId: string, assertion: unknown, expectedChallengeHash: string): Promise<boolean> {
    try {
      const response = assertion as { id?: unknown };
      if (!response || typeof response.id !== 'string') return false;
      const credential = await this.cfg.lookupCredential(userId, response.id);
      if (!credential) return false;
      const r = await verifyAuthenticationResponse({
        response: assertion as Parameters<typeof verifyAuthenticationResponse>[0]['response'],
        expectedChallenge: (c) => Buffer.from(c, 'base64url').toString('utf8') === expectedChallengeHash,
        expectedOrigin: this.cfg.expectedOrigin,
        expectedRPID: this.cfg.expectedRPID,
        credential,
        requireUserVerification: true,
      });
      return r.verified;
    } catch {
      return false;
    }
  }
}
