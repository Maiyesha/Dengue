import { describe, it, expect } from 'vitest';
import { createHash } from 'node:crypto';
import { Readable } from 'node:stream';
import { S3Client } from '@aws-sdk/client-s3';
import { S3ObjectStore } from '../../src/objectStore';

function mockClient(respond: (cmd: { constructor: { name: string }; input: Record<string, unknown> }) => unknown) {
  const sent: Array<{ name: string; input: Record<string, unknown> }> = [];
  const client = {
    config: { region: async () => 'ap-southeast-5', credentials: async () => ({ accessKeyId: 'a', secretAccessKey: 'b' }) },
    send: async (cmd: any) => {
      sent.push({ name: cmd.constructor.name, input: cmd.input });
      return respond(cmd);
    },
  } as unknown as S3Client;
  return { client, sent };
}

describe('S3ObjectStore', () => {
  it('sha256 streams the object and returns the whole-object hex digest', async () => {
    const bytes = [Buffer.from('hello '), Buffer.from('world')];
    const { client, sent } = mockClient(() => ({ Body: Readable.from(bytes) }));
    const store = new S3ObjectStore({ bucket: 'b', client });
    expect(await store.sha256('k')).toBe(createHash('sha256').update('hello world').digest('hex'));
    expect(sent[0].name).toBe('GetObjectCommand');
  });

  it('createMultipart sends no checksum algorithm', async () => {
    const { client, sent } = mockClient(() => ({ UploadId: 'u1' }));
    const store = new S3ObjectStore({ bucket: 'b', client });
    expect(await store.createMultipart('k')).toBe('u1');
    expect(sent[0].input).toEqual({ Bucket: 'b', Key: 'k' });
    expect(sent[0].input).not.toHaveProperty('ChecksumAlgorithm');
  });

  it('presignPart URL carries no checksum parameters', async () => {
    // Presigning is offline: build the store's own client with dummy credentials.
    process.env.AWS_ACCESS_KEY_ID = 'a';
    process.env.AWS_SECRET_ACCESS_KEY = 'b';
    const store = new S3ObjectStore({ bucket: 'b', region: 'ap-southeast-5' });
    const url = await store.presignPart('k', 'u1', 3, 900);
    expect(url).toContain('partNumber=3');
    expect(url).toContain('X-Amz-Expires=900');
    expect(url.toLowerCase()).not.toContain('checksum');
    expect(url.toLowerCase()).not.toContain('x-amz-sdk-checksum');
  });
});
