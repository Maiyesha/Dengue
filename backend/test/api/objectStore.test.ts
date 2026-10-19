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

  const s3Error = (name: string, status: number) =>
    Object.assign(new Error(name), { name, Code: name, $metadata: { httpStatusCode: status } });

  describe('completeMultipart', () => {
    it('sums ListParts sizes across pages and completes when the total reaches size_bytes', async () => {
      const { client, sent } = mockClient((cmd) => {
        if (cmd.constructor.name === 'ListPartsCommand') {
          return cmd.input.PartNumberMarker === undefined
            ? { Parts: [{ PartNumber: 1, ETag: '"e1"', Size: 6 }], IsTruncated: true, NextPartNumberMarker: '1' }
            : { Parts: [{ PartNumber: 2, ETag: '"e2"', Size: 4 }], IsTruncated: false };
        }
        return {};
      });
      const store = new S3ObjectStore({ bucket: 'b', client });
      expect(await store.completeMultipart('k', 'u1', 10)).toEqual({ completed: true });
      const complete = sent.find((s) => s.name === 'CompleteMultipartUploadCommand');
      expect(complete?.input.MultipartUpload).toEqual({ Parts: [{ PartNumber: 1, ETag: '"e1"' }, { PartNumber: 2, ETag: '"e2"' }] });
    });

    it('fewer bytes than size_bytes -> incomplete, no CompleteMultipartUpload sent', async () => {
      const { client, sent } = mockClient((cmd) =>
        cmd.constructor.name === 'ListPartsCommand' ? { Parts: [{ PartNumber: 1, ETag: '"e1"', Size: 6 }], IsTruncated: false } : {},
      );
      const store = new S3ObjectStore({ bucket: 'b', client });
      expect(await store.completeMultipart('k', 'u1', 10)).toEqual({ completed: false, receivedBytes: 6 });
      expect(sent.map((s) => s.name)).toEqual(['ListPartsCommand']);
    });

    it('NoSuchUpload on ListParts + object exists (HeadObject) -> already completed', async () => {
      const { client, sent } = mockClient((cmd) => {
        if (cmd.constructor.name === 'ListPartsCommand') throw s3Error('NoSuchUpload', 404);
        if (cmd.constructor.name === 'HeadObjectCommand') return { ContentLength: 10 };
        throw new Error(`unexpected ${cmd.constructor.name}`);
      });
      const store = new S3ObjectStore({ bucket: 'b', client });
      expect(await store.completeMultipart('k', 'u1', 10)).toEqual({ completed: true });
      expect(sent.map((s) => s.name)).toEqual(['ListPartsCommand', 'HeadObjectCommand']);
      expect(sent[1].input).toEqual({ Bucket: 'b', Key: 'k' });
    });

    it('NoSuchUpload on CompleteMultipartUpload + object exists -> already completed', async () => {
      const { client } = mockClient((cmd) => {
        if (cmd.constructor.name === 'ListPartsCommand') return { Parts: [{ PartNumber: 1, ETag: '"e1"', Size: 10 }] };
        if (cmd.constructor.name === 'CompleteMultipartUploadCommand') throw s3Error('NoSuchUpload', 404);
        return {};
      });
      const store = new S3ObjectStore({ bucket: 'b', client });
      expect(await store.completeMultipart('k', 'u1', 10)).toEqual({ completed: true });
    });

    it('NoSuchUpload and no object -> rejects', async () => {
      const { client } = mockClient((cmd) => {
        if (cmd.constructor.name === 'ListPartsCommand') throw s3Error('NoSuchUpload', 404);
        throw s3Error('NotFound', 404);
      });
      const store = new S3ObjectStore({ bucket: 'b', client });
      await expect(store.completeMultipart('k', 'u1', 10)).rejects.toThrow(/NoSuchUpload/);
    });

    it('other S3 errors propagate', async () => {
      const { client } = mockClient(() => {
        throw s3Error('InternalError', 500);
      });
      const store = new S3ObjectStore({ bucket: 'b', client });
      await expect(store.completeMultipart('k', 'u1', 10)).rejects.toThrow(/InternalError/);
    });
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
