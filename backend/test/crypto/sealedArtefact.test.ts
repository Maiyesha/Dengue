// C1: the server reads device uploads. The fixture in contracts/fixtures/sealed-artefact-v1 is produced by the
// Swift core tests (ArtefactSealer + RSAKeyWrapper, TEST-ONLY RSA key) and decrypted here end to end.
import { createHash, generateKeyPairSync, publicEncrypt, constants, randomBytes, createCipheriv } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, it, expect } from 'vitest';
import { openSealed, SealedArtefactError } from '../../src/crypto/sealedArtefact';
import { LocalRsaUnwrapper, AwsKmsUnwrapper, KEY_ALG } from '../../src/crypto/kms';

const dir = resolve(dirname(fileURLToPath(import.meta.url)), '../../../contracts/fixtures/sealed-artefact-v1');
const manifest = JSON.parse(readFileSync(resolve(dir, 'manifest.json'), 'utf8'));
const sealed = readFileSync(resolve(dir, manifest.sealed_file));
const plaintext = readFileSync(resolve(dir, manifest.plaintext_file));
const privatePem = readFileSync(resolve(dir, manifest.private_key_file), 'utf8');
const sha = (b: Buffer) => createHash('sha256').update(b).digest('hex');

async function fixtureDek(): Promise<Buffer> {
  return new LocalRsaUnwrapper(privatePem).unwrap({
    wrappedKey: manifest.wrapped_key_b64, keyAlg: manifest.key_alg, kmsKeyId: manifest.kms_key_id,
  });
}

describe('sealed artefact fixture (Swift -> Node)', () => {
  it('manifest matches the files', () => {
    expect(manifest.format).toBe('DSv1');
    expect(manifest.key_alg).toBe(KEY_ALG);
    expect(sha(sealed)).toBe(manifest.sealed_sha256);
    expect(sealed.length).toBe(manifest.sealed_size_bytes);
    expect(sha(plaintext)).toBe(manifest.plaintext_sha256);
  });

  it('unwrap -> openSealed -> equals the plaintext', async () => {
    const dek = await fixtureDek();
    expect(dek.length).toBe(32);
    const out = openSealed(sealed, dek);
    expect(out.length).toBe(plaintext.length);
    expect(out.equals(plaintext)).toBe(true);
  });

  it('tampering with any ciphertext byte throws', async () => {
    const dek = await fixtureDek();
    for (const at of [13, 1 << 20, sealed.length - 1]) {
      const t = Buffer.from(sealed);
      t[at] ^= 0x01;
      expect(() => openSealed(t, dek)).toThrow(SealedArtefactError);
    }
  });

  it('header tampering throws (magic, version, nonce prefix)', async () => {
    const dek = await fixtureDek();
    for (const at of [0, 4, 5]) {
      const t = Buffer.from(sealed);
      t[at] ^= 0x01;
      expect(() => openSealed(t, dek)).toThrow(SealedArtefactError);
    }
  });

  it('truncation throws (mid-chunk, at a chunk boundary, header only, empty)', async () => {
    const dek = await fixtureDek();
    const chunk = (1 << 20) + 16;
    for (const len of [sealed.length - 1, 13 + chunk, 13, 5, 0]) {
      expect(() => openSealed(sealed.subarray(0, len), dek)).toThrow(SealedArtefactError);
    }
  });

  it('trailing bytes after the final chunk throw', async () => {
    const dek = await fixtureDek();
    expect(() => openSealed(Buffer.concat([sealed, Buffer.alloc(1)]), dek)).toThrow(SealedArtefactError);
    expect(() => openSealed(Buffer.concat([sealed, Buffer.alloc(17)]), dek)).toThrow(SealedArtefactError);
  });

  it('wrong key throws', () => {
    expect(() => openSealed(sealed, randomBytes(32))).toThrow(SealedArtefactError);
    expect(() => openSealed(sealed, randomBytes(16))).toThrow(SealedArtefactError);
  });

  it('a chunk that is final but not flagged final is rejected (truncated exactly after chunk 0)', () => {
    // Build a 2-chunk file by hand, then drop the final chunk: chunk 0 was sealed with isFinal = 0.
    const dek = randomBytes(32);
    const prefix = randomBytes(8);
    const seal = (i: number, data: Buffer, final: boolean) => {
      const nonce = Buffer.concat([prefix, Buffer.from([i >>> 24, (i >>> 16) & 255, (i >>> 8) & 255, i & 255])]);
      const c = createCipheriv('aes-256-gcm', dek, nonce);
      c.setAAD(Buffer.concat([nonce.subarray(8), Buffer.from([final ? 1 : 0])]));
      return Buffer.concat([c.update(data), c.final(), c.getAuthTag()]);
    };
    const head = Buffer.concat([Buffer.from('DSv1'), Buffer.from([1]), prefix]);
    const full = Buffer.concat([head, seal(0, Buffer.alloc(1 << 20, 7), false), seal(1, Buffer.from('end'), true)]);
    expect(openSealed(full, dek).length).toBe((1 << 20) + 3);
    expect(() => openSealed(full.subarray(0, head.length + (1 << 20) + 16), dek)).toThrow(SealedArtefactError);
  });
});

describe('KMS unwrappers', () => {
  it('LocalRsaUnwrapper rejects another alg and a wrong key', async () => {
    const u = new LocalRsaUnwrapper(privatePem);
    await expect(u.unwrap({ wrappedKey: manifest.wrapped_key_b64, keyAlg: 'RSA-OAEP', kmsKeyId: 'x' })).rejects.toThrow();
    const other = generateKeyPairSync('rsa', { modulusLength: 2048 });
    const wrapped = publicEncrypt(
      { key: other.publicKey, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, randomBytes(32),
    ).toString('base64');
    await expect(u.unwrap({ wrappedKey: wrapped, keyAlg: KEY_ALG, kmsKeyId: 'x' })).rejects.toThrow();
  });

  it('AwsKmsUnwrapper sends Decrypt with RSAES_OAEP_SHA_256 and the key id (stub client, no network)', async () => {
    const sent: unknown[] = [];
    const client = { send: async (cmd: { input: unknown }) => { sent.push(cmd.input); return { Plaintext: new Uint8Array(32).fill(9) }; } };
    const u = new AwsKmsUnwrapper(client);
    const dek = await u.unwrap({ wrappedKey: Buffer.from('ct').toString('base64'), keyAlg: KEY_ALG, kmsKeyId: 'arn:aws:kms:k' });
    expect(dek.equals(Buffer.alloc(32, 9))).toBe(true);
    expect(sent[0]).toMatchObject({ KeyId: 'arn:aws:kms:k', EncryptionAlgorithm: 'RSAES_OAEP_SHA_256' });
    expect(Buffer.from((sent[0] as { CiphertextBlob: Uint8Array }).CiphertextBlob).toString()).toBe('ct');
  });
});
