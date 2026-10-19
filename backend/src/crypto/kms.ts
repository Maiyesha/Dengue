// Unwrapping of per-artefact data keys (C1 envelope encryption). The device wraps each 32-byte DEK with the
// server KMS RSA public key (RSA-OAEP, SHA-256 for both OAEP digest and MGF1) and declares it with the artefact
// (artefacts.wrapped_key / key_alg / kms_key_id). The quality worker unwraps it here, then calls openSealed().
import { constants, createPrivateKey, privateDecrypt, type KeyObject } from 'node:crypto';
import { DecryptCommand, KMSClient } from '@aws-sdk/client-kms';

export const KEY_ALG = 'RSA-OAEP-256' as const;

export interface WrappedDataKey {
  /** base64 RSA-OAEP-SHA256 ciphertext of the raw 32-byte DEK. */
  wrappedKey: string;
  keyAlg: string;
  kmsKeyId: string;
}

export interface KmsUnwrapper {
  /** Returns the 32-byte DEK; throws if the alg is not RSA-OAEP-256 or decryption fails. */
  unwrap(k: WrappedDataKey): Promise<Buffer>;
}

function checked(k: WrappedDataKey): Buffer {
  if (k.keyAlg !== KEY_ALG) throw new Error(`unsupported key_alg ${k.keyAlg}`);
  return Buffer.from(k.wrappedKey, 'base64');
}

function dekOf(b: Buffer | Uint8Array | undefined): Buffer {
  if (!b || b.length !== 32) throw new Error('unwrapped data key must be 32 bytes');
  return Buffer.from(b);
}

/** Local RSA private key (tests, and local development only). */
export class LocalRsaUnwrapper implements KmsUnwrapper {
  private readonly key: KeyObject;
  constructor(privateKeyPem: string) {
    this.key = createPrivateKey(privateKeyPem);
  }
  async unwrap(k: WrappedDataKey): Promise<Buffer> {
    const ct = checked(k);
    return dekOf(privateDecrypt({ key: this.key, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, ct));
  }
}

/** Minimal client surface so tests can stub it (no network). */
export interface KmsSendClient {
  send(command: DecryptCommand): Promise<{ Plaintext?: Uint8Array }>;
}

/** AWS KMS asymmetric RSA key: Decrypt with RSAES_OAEP_SHA_256. Not network-tested. */
export class AwsKmsUnwrapper implements KmsUnwrapper {
  constructor(private readonly client: KmsSendClient = new KMSClient({})) {}
  async unwrap(k: WrappedDataKey): Promise<Buffer> {
    const ct = checked(k);
    const r = await this.client.send(
      new DecryptCommand({ KeyId: k.kmsKeyId, CiphertextBlob: ct, EncryptionAlgorithm: 'RSAES_OAEP_SHA_256' }),
    );
    return dekOf(r.Plaintext);
  }
}
