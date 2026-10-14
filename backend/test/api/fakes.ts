// In-memory fakes for every external dependency in AppDeps (except pool / JWT keys).
import type {
  AppAttestVerifier, AssertionVerifier, ObjectStore, PushSender, QualityQueue,
} from '../../src/deps';

export class FakeObjectStore implements ObjectStore {
  private n = 0;
  /** key -> sha256 hex of the stored (completed) object; tests set it via put(). */
  readonly objects = new Map<string, string>();
  readonly uploads = new Map<string, { key: string; completed: boolean }>();

  /** Sets the sha256 the store will report for `key` (tests use a wrong value to simulate corruption). */
  put(key: string, sha256: string): void {
    this.objects.set(key, sha256);
  }
  async createMultipart(key: string): Promise<string> {
    const uploadId = `upload-${++this.n}`;
    this.uploads.set(uploadId, { key, completed: false });
    return uploadId;
  }
  async presignPart(key: string, uploadId: string, partNumber: number, ttlSec: 900): Promise<string> {
    return `https://fake-s3.local/${encodeURIComponent(key)}?uploadId=${uploadId}&partNumber=${partNumber}&X-Amz-Expires=${ttlSec}`;
  }
  async completeMultipart(_key: string, uploadId: string): Promise<void> {
    const u = this.uploads.get(uploadId);
    if (u) u.completed = true;
  }
  async sha256(key: string): Promise<string> {
    const v = this.objects.get(key);
    if (v === undefined) throw new Error(`fake object store: no object ${key}`);
    return v;
  }
}

export class FakeQualityQueue implements QualityQueue {
  readonly enqueued: string[] = [];
  async enqueue(scanId: string): Promise<void> {
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
