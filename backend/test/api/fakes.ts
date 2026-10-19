// In-memory fakes for every external dependency in AppDeps (except pool / JWT keys).
import type {
  AppAttestVerifier, AssertionVerifier, CompleteResult, ObjectStore, PushSender, QualityQueue,
} from '../../src/deps';

/**
 * Models the S3 semantics the API depends on (as seen through S3ObjectStore):
 *  - completing an upload is NOT idempotent at S3: the upload id disappears (NoSuchUpload); the
 *    store then reports success only if the object exists (S3ObjectStore's HeadObject fallback);
 *  - completion requires the uploaded parts to add up to size_bytes, else { completed: false }.
 * put(key, sha) simulates the client having uploaded ALL bytes of `key` (content hashing to sha);
 * put(key, sha, { full: false }) + uploadPart() simulates a partial upload.
 */
export class FakeObjectStore implements ObjectStore {
  private n = 0;
  /** key -> sha256 hex the object's content hashes to; tests set it via put(). */
  readonly objects = new Map<string, string>();
  readonly uploads = new Map<string, { key: string; completed: boolean; parts: Map<number, number> }>();
  /** Keys whose content has been fully uploaded (put() without full:false). */
  private readonly full = new Set<string>();
  /** Keys that exist as completed objects. */
  readonly completedKeys = new Set<string>();
  completeCalls = 0;
  /** When > 0, sha256() throws (transient read failure) and decrements. */
  failSha256 = 0;

  /** Sets the sha256 the store will report for `key` (tests use a wrong value to simulate corruption). */
  put(key: string, sha256: string, o: { full?: boolean } = {}): void {
    this.objects.set(key, sha256);
    if (o.full === false) this.full.delete(key);
    else this.full.add(key);
  }
  /** Records an uploaded part of `size` bytes on the newest open upload of `key`. */
  uploadPart(key: string, partNumber: number, size: number): void {
    const open = [...this.uploads.values()].filter((u) => u.key === key && !u.completed).pop();
    if (!open) throw new Error(`fake object store: no open upload for ${key}`);
    open.parts.set(partNumber, size);
  }
  async createMultipart(key: string): Promise<string> {
    const uploadId = `upload-${++this.n}`;
    this.uploads.set(uploadId, { key, completed: false, parts: new Map() });
    return uploadId;
  }
  private signed = 0;
  async presignPart(key: string, uploadId: string, partNumber: number, ttlSec: 900): Promise<string> {
    // Like a real presign (X-Amz-Date / signature), every URL is distinct.
    const sig = ++this.signed;
    return `https://fake-s3.local/${encodeURIComponent(key)}?uploadId=${uploadId}&partNumber=${partNumber}&X-Amz-Expires=${ttlSec}&X-Amz-Signature=${sig}`;
  }
  async completeMultipart(key: string, uploadId: string, expectedBytes: number): Promise<CompleteResult> {
    this.completeCalls++;
    const u = this.uploads.get(uploadId);
    if (!u || u.completed || u.key !== key) {
      // S3: NoSuchUpload. Completed already (e.g. the earlier request's DB work rolled back)?
      if (this.completedKeys.has(key)) return { completed: true };
      throw Object.assign(new Error('NoSuchUpload'), { name: 'NoSuchUpload' });
    }
    const received = this.full.has(key) ? expectedBytes : [...u.parts.values()].reduce((a, b) => a + b, 0);
    if (received < expectedBytes) return { completed: false, receivedBytes: received };
    u.completed = true;
    this.completedKeys.add(key);
    return { completed: true };
  }
  async sha256(key: string): Promise<string> {
    if (this.failSha256 > 0) {
      this.failSha256--;
      throw new Error('fake object store: transient GetObject failure');
    }
    const v = this.objects.get(key);
    if (v === undefined) throw new Error(`fake object store: no object ${key}`);
    return v;
  }
}

export class FakeQualityQueue implements QualityQueue {
  readonly enqueued: string[] = [];
  /** When > 0, enqueue() throws (queue unavailable) and decrements. */
  fail = 0;
  async enqueue(scanId: string): Promise<void> {
    if (this.fail > 0) {
      this.fail--;
      throw new Error('fake queue: unavailable');
    }
    this.enqueued.push(scanId);
  }
}

export class FakeAppAttest implements AppAttestVerifier {
  publicKey = Buffer.from('fake-attest-public-key');
  fail = false;
  readonly attestations: Array<{ keyId: string; attestationObject: Buffer; challenge: Buffer }> = [];
  readonly assertions: Array<{ publicKey: Buffer; assertion: Buffer; clientDataHash: Buffer; prevCounter: number }> = [];
  async verifyAttestation(keyId: string, attestationObject: Buffer, challenge: Buffer): Promise<{ publicKey: Buffer }> {
    this.attestations.push({ keyId, attestationObject, challenge });
    if (this.fail) throw new Error('attestation invalid');
    return { publicKey: this.publicKey };
  }
  async verifyAssertion(publicKey: Buffer, assertion: Buffer, clientDataHash: Buffer, prevCounter: number): Promise<{ counter: number }> {
    this.assertions.push({ publicKey, assertion, clientDataHash, prevCounter });
    if (this.fail) throw new Error('assertion invalid');
    // Fake encoding: the assertion buffer's text is the counter value; default prev+1.
    // Deliberately does NOT enforce monotonicity: the route must.
    const n = Number(assertion.toString('utf8'));
    return { counter: Number.isFinite(n) && assertion.length > 0 ? n : prevCounter + 1 };
  }
}

export class FakeWebauthn implements AssertionVerifier {
  result = true;
  readonly calls: Array<{ userId: string; assertion: unknown; expectedChallengeHash: string }> = [];
  async verify(userId: string, assertion: unknown, expectedChallengeHash: string): Promise<boolean> {
    this.calls.push({ userId, assertion, expectedChallengeHash });
    return this.result;
  }
}

export class FakePush implements PushSender {
  readonly sent: Array<{ deviceId: string; payload: { type: string; [k: string]: unknown } }> = [];
  async send(deviceId: string, payload: { type: string; [k: string]: unknown }): Promise<void> {
    this.sent.push({ deviceId, payload });
  }
}
