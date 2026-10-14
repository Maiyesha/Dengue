// S3-backed ObjectStore (AWS SDK v3). Bucket/region come from S3_BUCKET / S3_REGION.
import {
  CompleteMultipartUploadCommand,
  CreateMultipartUploadCommand,
  GetObjectAttributesCommand,
  ListPartsCommand,
  S3Client,
  UploadPartCommand,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { ObjectStore } from './deps';

/** S3 reports ChecksumSHA256 as base64; the API compares lowercase hex. */
export function base64ToHex(b64: string): string {
  return Buffer.from(b64, 'base64').toString('hex');
}

export class S3ObjectStore implements ObjectStore {
  private readonly s3: S3Client;
  private readonly bucket: string;

  constructor(opts: { bucket?: string; region?: string; client?: S3Client } = {}) {
    const bucket = opts.bucket ?? process.env.S3_BUCKET;
    const region = opts.region ?? process.env.S3_REGION;
    if (!bucket) throw new Error('S3_BUCKET is not set');
    if (!region && !opts.client) throw new Error('S3_REGION is not set');
    this.bucket = bucket;
    this.s3 = opts.client ?? new S3Client({ region });
  }

  async createMultipart(key: string): Promise<string> {
    const r = await this.s3.send(
      new CreateMultipartUploadCommand({ Bucket: this.bucket, Key: key, ChecksumAlgorithm: 'SHA256' }),
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

  async completeMultipart(key: string, uploadId: string): Promise<void> {
    const parts: Array<{ PartNumber: number; ETag: string; ChecksumSHA256?: string }> = [];
    let marker: string | undefined;
    for (;;) {
      const r = await this.s3.send(
        new ListPartsCommand({ Bucket: this.bucket, Key: key, UploadId: uploadId, PartNumberMarker: marker }),
      );
      for (const p of r.Parts ?? []) {
        if (p.PartNumber !== undefined && p.ETag) {
          parts.push({ PartNumber: p.PartNumber, ETag: p.ETag, ChecksumSHA256: p.ChecksumSHA256 });
        }
      }
      if (!r.IsTruncated) break;
      marker = r.NextPartNumberMarker;
    }
    await this.s3.send(
      new CompleteMultipartUploadCommand({
        Bucket: this.bucket,
        Key: key,
        UploadId: uploadId,
        MultipartUpload: { Parts: parts },
      }),
    );
  }

  /** Hex sha256 of the whole object (object-level checksum). */
  async sha256(key: string): Promise<string> {
    const r = await this.s3.send(
      new GetObjectAttributesCommand({ Bucket: this.bucket, Key: key, ObjectAttributes: ['Checksum'] }),
    );
    const b64 = r.Checksum?.ChecksumSHA256;
    if (!b64) throw new Error(`no SHA-256 checksum on object ${key}`);
    return base64ToHex(b64);
  }
}
