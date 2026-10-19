// DSv1 sealed artefact reader: the exact counterpart of the iOS ArtefactSealer (ios/DengueCaptureCore).
//
// Format: "DSv1" | version (1 byte, = 1) | 8-byte random nonce prefix | chunks.
// Each chunk is AES-256-GCM over up to 1 MiB of plaintext, stored as ciphertext || 16-byte tag.
// Nonce = prefix || BE32(chunk index). AAD = BE32(chunk index) || isFinal (1 byte: 1 for the last chunk).
// The final chunk is the last one in the file (an empty input is one empty final chunk). Reordering,
// truncation (also exactly at a chunk boundary), extension and tampering all fail.
import { createDecipheriv } from 'node:crypto';

export class SealedArtefactError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SealedArtefactError';
  }
}

const MAGIC = Buffer.from('DSv1');
const VERSION = 1;
const PREFIX_LEN = 8;
const HEADER_LEN = MAGIC.length + 1 + PREFIX_LEN;
const CHUNK_SIZE = 1 << 20;
const TAG_LEN = 16;
const SEALED_CHUNK = CHUNK_SIZE + TAG_LEN;

const be32 = (i: number) => {
  const b = Buffer.alloc(4);
  b.writeUInt32BE(i);
  return b;
};

/** Decrypts a whole DSv1 file with its 32-byte data key. Throws SealedArtefactError on any defect. */
export function openSealed(bytes: Buffer, dek: Buffer): Buffer {
  if (dek.length !== 32) throw new SealedArtefactError('data key must be 32 bytes');
  if (bytes.length < HEADER_LEN + TAG_LEN) throw new SealedArtefactError('truncated');
  if (!bytes.subarray(0, MAGIC.length).equals(MAGIC)) throw new SealedArtefactError('bad magic');
  if (bytes[MAGIC.length] !== VERSION) throw new SealedArtefactError('unsupported version');
  const prefix = bytes.subarray(MAGIC.length + 1, HEADER_LEN);

  const out: Buffer[] = [];
  let offset = HEADER_LEN;
  let index = 0;
  for (;;) {
    const remaining = bytes.length - offset;
    // Mirrors the sealer's read-ahead: a full chunk with nothing after it is final; a short chunk is final.
    const len = Math.min(remaining, SEALED_CHUNK);
    if (len < TAG_LEN) throw new SealedArtefactError('truncated chunk');
    const isFinal = offset + len === bytes.length;
    const chunk = bytes.subarray(offset, offset + len);
    const nonce = Buffer.concat([prefix, be32(index)]);
    try {
      const d = createDecipheriv('aes-256-gcm', dek, nonce, { authTagLength: TAG_LEN });
      d.setAAD(Buffer.concat([be32(index), Buffer.from([isFinal ? 1 : 0])]));
      d.setAuthTag(chunk.subarray(len - TAG_LEN));
      out.push(d.update(chunk.subarray(0, len - TAG_LEN)), d.final());
    } catch {
      throw new SealedArtefactError(`chunk ${index} failed authentication`);
    }
    offset += len;
    if (isFinal) break;
    if (index === 0xffffffff) throw new SealedArtefactError('too many chunks');
    index += 1;
  }
  // Trailing bytes cannot survive (they become part of a chunk that fails authentication); defensive check.
  if (offset !== bytes.length) throw new SealedArtefactError('trailing bytes');
  return Buffer.concat(out);
}
