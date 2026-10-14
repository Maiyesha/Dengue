// Real AssertionVerifier backed by @simplewebauthn/server. Unit-tested with the library mocked
// (no real authenticator available); this class is a thin adapter.
import { createHash } from 'node:crypto';
import { verifyAuthenticationResponse, type WebAuthnCredential } from '@simplewebauthn/server';
import type { AssertionVerifier } from './deps';

export interface WebauthnConfig {
  expectedOrigin: string | string[];
  expectedRPID: string | string[];
  /** Registered credential for the user matching the assertion's credential id; null if unknown. */
  lookupCredential(userId: string, credentialId: string): Promise<WebAuthnCredential | null>;
  /**
   * Persists the authenticator's new signature counter after a successful verification (clone
   * detection). Interface only in plan 02: the credential store is provided by the deployment.
   * If it throws, the verification is treated as failed (fail closed).
   */
  updateCounter(credentialId: string, newCounter: number): Promise<void>;
}

export class SimpleWebauthnVerifier implements AssertionVerifier {
  constructor(private readonly cfg: WebauthnConfig) {}

  /**
   * `expectedChallengeHash` is the stored sha256 hex of the raw server-issued review challenge
   * (POST /v1/scans/{id}/review-challenge). The authenticator signs the raw 32 bytes; clientDataJSON
   * carries them base64url-encoded, so the challenge matches when sha256(decoded) equals the hash.
   */
  async verify(userId: string, assertion: unknown, expectedChallengeHash: string): Promise<boolean> {
    try {
      const response = assertion as { id?: unknown };
      if (!response || typeof response.id !== 'string') return false;
      const credential = await this.cfg.lookupCredential(userId, response.id);
      if (!credential) return false;
      const r = await verifyAuthenticationResponse({
        response: assertion as Parameters<typeof verifyAuthenticationResponse>[0]['response'],
        expectedChallenge: (c) =>
          createHash('sha256').update(Buffer.from(c, 'base64url')).digest('hex') === expectedChallengeHash,
        expectedOrigin: this.cfg.expectedOrigin,
        expectedRPID: this.cfg.expectedRPID,
        credential,
        requireUserVerification: true,
      });
      if (!r.verified) return false;
      await this.cfg.updateCounter(credential.id, r.authenticationInfo.newCounter);
      return true;
    } catch {
      return false;
    }
  }
}
