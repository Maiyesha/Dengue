// S3-backed ObjectStore (AWS SDK v3). Bucket/region come from S3_BUCKET / S3_REGION.
import {
  CompleteMultipartUploadCommand,
  CreateMultipartUploadCommand,
  GetObjectCommand,
  HeadObjectCommand,
  ListPartsCommand,
  S3Client,
  UploadPartCommand,
} from '@aws-sdk/client-s3';
import { createHash } from 'node:crypto';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { CompleteResult, ObjectStore } from './deps';

const isNoSuchUpload = (e: unknown) => {
  const x = e as { name?: string; Code?: string } | null;
  return x?.name === 'NoSuchUpload' || x?.Code === 'NoSuchUpload';
};

export class S3ObjectStore implements ObjectStore {
  private readonly s3: S3Client;
  private readonly bucket: string;

  constructor(opts: { bucket?: string; region?: string; client?: S3Client } = {}) {
    const bucket = opts.bucket ?? process.env.S3_BUCKET;
    const region = opts.region ?? process.env.S3_REGION;
    if (!bucket) throw new Error('S3_BUCKET is not set');
    if (!region && !opts.client) throw new Error('S3_REGION is not set');
    this.bucket = bucket;
    this.s3 = opts.client ?? new S3Client({ region, requestChecksumCalculation: 'WHEN_REQUIRED' }) // no default CRC32 on parts;
  }

  async createMultipart(key: string): Promise<string> {
    const r = await this.s3.send(
      new CreateMultipartUploadCommand({ Bucket: this.bucket, Key: key }),
    );
    if (!r.UploadId) throw new Error('S3 returned no UploadId');
    return r.UploadId;
  }

  presignPart(key: string, uploadId: string, partNumber: number, ttlSec: 900): Promise<string> {
    return getSignedUrl(
      this.s3,
      new UploadPartCommand({ Bucket: this.bucket, Key: key, UploadId: uploadId, PartNumber: partNumber }),
      { expiresIn: ttlSec },
    );
  }

  /**
   * CompleteMultipartUpload is not idempotent at S3: once it succeeds the upload id is gone and a
   * retry gets NoSuchUpload. That happens when our DB transaction rolled back after S3 completed,
   * so on NoSuchUpload (from ListParts or Complete) we HeadObject the key: if the object exists the
   * upload was completed earlier and we report success; otherwise the original error is rethrown.
   * Before completing, the ListParts sizes are summed; fewer bytes than `expectedBytes` means parts
   * are still missing, reported as { completed: false } without touching the upload.
   */
  async completeMultipart(key: string, uploadId: string, expectedBytes: number): Promise<CompleteResult> {
    const parts: Array<{ PartNumber: number; ETag: string }> = [];
    let received = 0;
    try {
      let marker: string | undefined;
      for (;;) {
        const r = await this.s3.send(
          new ListPartsCommand({ Bucket: this.bucket, Key: key, UploadId: uploadId, PartNumberMarker: marker }),
        );
        for (const p of r.Parts ?? []) {
          if (p.PartNumber !== undefined && p.ETag) {
            parts.push({ PartNumber: p.PartNumber, ETag: p.ETag });
            received += p.Size ?? 0;
          }
        }
        if (!r.IsTruncated) break;
        marker = r.NextPartNumberMarker;
      }
    } catch (e) {
      return this.completedEarlier(key, e);
    }
    if (received < expectedBytes) return { completed: false, receivedBytes: received };
    try {
      await this.s3.send(
        new CompleteMultipartUploadCommand({
          Bucket: this.bucket,
          Key: key,
          UploadId: uploadId,
          MultipartUpload: { Parts: parts },
        }),
      );
    } catch (e) {
      return this.completedEarlier(key, e);
    }
    return { completed: true };
  }

  /** NoSuchUpload + existing object => completed by an earlier call; anything else rethrows `err`. */
  private async completedEarlier(key: string, err: unknown): Promise<CompleteResult> {
    if (!isNoSuchUpload(err)) throw err;
    try {
      await this.s3.send(new HeadObjectCommand({ Bucket: this.bucket, Key: key }));
    } catch {
      throw err;
    }
    return { completed: true };
  }

  /**
   * Hex sha256 of the whole object, computed by streaming it. S3 multipart checksums are
   * composite (a hash of part hashes), so they can never equal a whole-file sha256.
   */
  async sha256(key: string): Promise<string> {
    const r = await this.s3.send(new GetObjectCommand({ Bucket: this.bucket, Key: key }));
    if (!r.Body) throw new Error(`object ${key} has no body`);
    const h = createHash('sha256');
    for await (const chunk of r.Body as AsyncIterable<Uint8Array>) h.update(chunk);
    return h.digest('hex');
  }
}
