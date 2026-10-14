import { describe, it, expect } from 'vitest';
import { createHash } from 'node:crypto';
import { base64ToHex } from '../../src/objectStore';

describe('base64ToHex', () => {
  it('converts an S3 base64 SHA-256 checksum to lowercase hex', () => {
    const d = createHash('sha256').update('abc').digest();
    expect(base64ToHex(d.toString('base64'))).toBe(d.toString('hex'));
  });
});
