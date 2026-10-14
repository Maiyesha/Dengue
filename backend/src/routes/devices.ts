// Device enrolment (Apple App Attest), device-token issue, and APNs push-token registration.
//
// Flow (the clinician/admin is signed in on the iPhone; the device has no credential yet):
//   1. POST /v1/devices/challenge  (user: admin|clinician)  -> { challenge }  32 random bytes, base64.
//      Only sha256(challenge) is stored (device_challenges), bound to the caller and the caller's
//      site, 5-minute TTL, single use.
//   2. POST /v1/devices/attest     (user: admin|clinician)  {key_id, attestation, challenge, ward_id}
//      -> 201 { device_id }. The device is bound to the caller's site and ward_id (a ward outside
//      the caller's site, or unknown, is 404).
//   3. POST /v1/devices/assert     (user: admin|clinician)  {device_id, assertion, challenge}
//      -> 200 { device_token, expires_in: 86400 }. clientDataHash passed to the verifier is
//      sha256(raw challenge). The assertion counter must strictly increase (else 401 DS_DEVICE_002);
//      the new counter is stored under a row lock in the same transaction that issues the token.
//   4. POST /v1/devices/push-token (device token, own device_id only, else 404) {device_id, apns_token}
//      -> 204.
//
// Challenges are consumed in their own committed transaction BEFORE verification, so a challenge
// is spent even when verification fails (no retry against the same challenge).
//
// All DB work runs as a server-internal actor with app.roles = system_agent, scoped to the
// caller's (or the device's) site; 0012_device_challenges.sql grants exactly what is needed.
// attest_public_key is read only via device_attest_public_key(); push_token is never readable.
//
// Errors: 401 DS_DEVICE_001 device revoked / not enrolled, 401 DS_DEVICE_002 assertion counter not
// increasing, 401 DS_DEVICE_003 challenge unknown / expired / used / not issued to the caller,
// 401 DS_DEVICE_004 attestation or assertion verification failed, 409 DS_DEVICE_005 key_id already
// enrolled, 404 DS_NOT_FOUND ward or device not visible to the caller.
import { createHash, randomBytes } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { ZodTypeProvider } from 'fastify-type-provider-zod';
import { ApiError } from '../errors';
import { actorOf, requireDevice, requireUser, type Actor } from '../auth';
import { withRls } from '../db';
import { audit, NO_PATIENT } from '../audit';
import { idempotent } from '../idempotency';
import { DEVICE_TOKEN_TTL_SEC } from '../deviceToken';

const CHALLENGE_BYTES = 32;

const notFound = () => new ApiError(404, 'DS_NOT_FOUND', 'Resource not found');
const forbidden = () => new ApiError(403, 'DS_AUTH_002', 'Not permitted for this route');
const deviceRevoked = () => new ApiError(401, 'DS_DEVICE_001', 'Device is not enrolled or has been revoked');
const counterReplay = () => new ApiError(401, 'DS_DEVICE_002', 'Assertion counter did not increase');
const badChallenge = () => new ApiError(401, 'DS_DEVICE_003', 'Challenge is unknown, expired or already used');
const verifyFailed = () => new ApiError(401, 'DS_DEVICE_004', 'App Attest verification failed');
const keyEnrolled = () => new ApiError(409, 'DS_DEVICE_005', 'This App Attest key is already enrolled');

/** Strict standard base64 (padded), non-empty, bounded. */
const b64 = (maxBytes: number) =>
  z
    .string()
    .min(4)
    .max(Math.ceil(maxBytes / 3) * 4)
    .regex(/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{4})$/, 'must be base64');

const Challenge = b64(CHALLENGE_BYTES).refine(
  (s) => Buffer.from(s, 'base64').length === CHALLENGE_BYTES,
  `challenge must be ${CHALLENGE_BYTES} bytes`,
);

const ChallengeBody = z.object({}).strict();
const AttestBody = z
  .object({
    key_id: z.string().min(1).max(256),
    attestation: b64(64 * 1024),
    challenge: Challenge,
    ward_id: z.string().min(1).max(100),
  })
  .strict();
const AssertBody = z
  .object({
    device_id: z.string().uuid(),
    assertion: b64(16 * 1024),
    challenge: Challenge,
  })
  .strict();
const PushTokenBody = z
  .object({
    device_id: z.string().uuid(),
    apns_token: z.string().regex(/^[0-9a-fA-F]{64,200}$/, 'must be a hex APNs device token'),
  })
  .strict();

const sha256 = (b: Buffer) => createHash('sha256').update(b).digest();

/** Server-internal actor for device DB work (validated again by withRls). */
const systemActor = (id: string, siteId: string): Actor => ({
  kind: 'user',
  id,
  roles: ['system_agent'],
  siteId,
  deidentify: true,
});

/** Caller must be a site-scoped user; device routes bind to that site. */
function siteOf(a: Actor): string {
  if (!a.siteId) throw forbidden();
  return a.siteId;
}

export async function deviceRoutes(app: FastifyInstance): Promise<void> {
  const r = app.withTypeProvider<ZodTypeProvider>();
  const pool = app.deps.pool;

  /** Spends the challenge in its own committed transaction; throws DS_DEVICE_003 if not spendable. */
  async function consumeChallenge(caller: Actor, siteId: string, challengeB64: string): Promise<Buffer> {
    const raw = Buffer.from(challengeB64, 'base64');
    const ok = await withRls(pool, systemActor(caller.id, siteId), async (c) => {
      const d = await c.query(
        `DELETE FROM device_challenges
          WHERE challenge_hash = $1 AND issued_to = $2 AND site_id = $3
          RETURNING expires_at > now() AS live`,
        [sha256(raw), caller.id, siteId],
      );
      return d.rows[0]?.live === true;
    });
    if (!ok) throw badChallenge();
    return raw;
  }

  /** Records a rejected device operation in its own transaction (the main one rolled back). */
  async function auditRejection(caller: Actor, siteId: string, deviceId: string, outcome: string, why: string) {
    try {
      await withRls(pool, systemActor(caller.id, siteId), (c) =>
        audit(c, {
          eventType: 'device_event',
          actorId: caller.id,
          actorRole: caller.roles[0],
          patientPseudonym: NO_PATIENT,
          resourceType: 'device',
          resourceId: deviceId,
          outcome,
          justification: why,
        }),
      );
    } catch {
      // Best effort: the request is already being rejected.
    }
  }

  const enroller = requireUser('admin', 'clinician');
  /** Runs after the role guard, before idempotent(): a site-less admin/clinician cannot enrol. */
  const requireSite = async (req: Parameters<typeof actorOf>[0]) => {
    siteOf(actorOf(req));
  };

  r.post(
    '/v1/devices/challenge',
    { preHandler: [enroller, requireSite, idempotent()], schema: { body: ChallengeBody } },
    async (req) => {
      const caller = actorOf(req);
      const siteId = siteOf(caller);
      const raw = randomBytes(CHALLENGE_BYTES);
      await withRls(pool, systemActor(caller.id, siteId), async (c) => {
        await c.query('DELETE FROM device_challenges WHERE site_id = $1 AND expires_at <= now()', [siteId]);
        await c.query(
          `INSERT INTO device_challenges (challenge_hash, issued_to, site_id, expires_at)
           VALUES ($1, $2, $3, now() + interval '5 minutes')`,
          [sha256(raw), caller.id, siteId],
        );
      });
      return { challenge: raw.toString('base64') };
    },
  );

  r.post(
    '/v1/devices/attest',
    { preHandler: [enroller, requireSite, idempotent()], schema: { body: AttestBody } },
    async (req, reply) => {
      const caller = actorOf(req);
      const siteId = siteOf(caller);
      const b = req.body;
      const challenge = await consumeChallenge(caller, siteId, b.challenge);

      const deviceId = await withRls(pool, systemActor(caller.id, siteId), async (c) => {
        const ward = (await c.query<{ site_id: string }>('SELECT site_id FROM wards WHERE id = $1', [b.ward_id])).rows[0];
        if (!ward || ward.site_id !== siteId) throw notFound();
        const dup = await c.query('SELECT 1 FROM devices WHERE app_attest_key_id = $1', [b.key_id]);
        if (dup.rowCount) throw keyEnrolled();

        let publicKey: Buffer;
        try {
          ({ publicKey } = await app.deps.appAttest.verifyAttestation(
            b.key_id,
            Buffer.from(b.attestation, 'base64'),
            challenge,
          ));
        } catch {
          throw verifyFailed();
        }
        if (!Buffer.isBuffer(publicKey) || publicKey.length === 0) throw verifyFailed();

        let id: string;
        try {
          id = (
            await c.query<{ id: string }>(
              `INSERT INTO devices (site_id, ward_id, app_attest_key_id, attest_public_key)
               VALUES ($1, $2, $3, $4) RETURNING id`,
              [siteId, b.ward_id, b.key_id, publicKey],
            )
          ).rows[0].id;
        } catch (e) {
          // Concurrent enrolment of the same key_id (unique constraint).
          if ((e as { code?: string }).code === '23505') throw keyEnrolled();
          throw e;
        }
        await audit(c, {
          eventType: 'device_event',
          actorId: caller.id,
          actorRole: caller.roles[0],
          patientPseudonym: NO_PATIENT,
          resourceType: 'device',
          resourceId: id,
          outcome: 'device:attested',
        });
        return id;
      });
      return reply.status(201).send({ device_id: deviceId });
    },
  );

  r.post(
    '/v1/devices/assert',
    { preHandler: [enroller, requireSite, idempotent()], schema: { body: AssertBody } },
    async (req) => {
      const caller = actorOf(req);
      const siteId = siteOf(caller);
      const b = req.body;
      const challenge = await consumeChallenge(caller, siteId, b.challenge);

      try {
        return await withRls(pool, systemActor(caller.id, siteId), async (c) => {
          const d = (
            await c.query<{ id: string; site_id: string; status: string; counter: string; pk: Buffer | null }>(
              `SELECT id, site_id, status, assertion_counter::text AS counter, device_attest_public_key(id) AS pk
                 FROM devices WHERE id = $1 AND site_id = $2 FOR UPDATE`,
              [b.device_id, siteId],
            )
          ).rows[0];
          if (!d) throw notFound();
          if (d.status !== 'active' || !d.pk) throw deviceRevoked();

          const prev = Number(d.counter);
          let counter: number;
          try {
            ({ counter } = await app.deps.appAttest.verifyAssertion(
              d.pk,
              Buffer.from(b.assertion, 'base64'),
              sha256(challenge),
              prev,
            ));
          } catch {
            throw verifyFailed();
          }
          if (!Number.isSafeInteger(counter) || counter <= prev) throw counterReplay();

          const up = await c.query(
            'UPDATE devices SET assertion_counter = $2 WHERE id = $1 AND assertion_counter < $2',
            [d.id, counter],
          );
          if (up.rowCount !== 1) throw counterReplay();
          await audit(c, {
            eventType: 'device_event',
            actorId: caller.id,
            actorRole: caller.roles[0],
            patientPseudonym: NO_PATIENT,
            resourceType: 'device',
            resourceId: d.id,
            outcome: 'device:asserted',
          });
          // Signed before COMMIT: if signing fails the counter is not advanced.
          const token = await app.deps.deviceTokenSigner.sign({ device_id: d.id, site_id: d.site_id });
          return { device_token: token, expires_in: DEVICE_TOKEN_TTL_SEC };
        });
      } catch (e) {
        if (e instanceof ApiError && /^DS_DEVICE_00[124]$/.test(e.code)) {
          await auditRejection(caller, siteId, b.device_id, 'device:assert_rejected', e.code);
        }
        throw e;
      }
    },
  );

  r.post(
    '/v1/devices/push-token',
    { preHandler: [requireDevice(), idempotent()], schema: { body: PushTokenBody } },
    async (req, reply) => {
      const device = actorOf(req);
      const b = req.body;
      if (b.device_id !== device.id) throw notFound();
      const siteId = siteOf(device);
      await withRls(pool, systemActor(device.id, siteId), async (c) => {
        const up = await c.query(
          `UPDATE devices SET push_token = $2 WHERE id = $1 AND site_id = $3 AND status = 'active'`,
          [device.id, b.apns_token, siteId],
        );
        if (up.rowCount !== 1) throw notFound();
        await audit(c, {
          eventType: 'device_event',
          actorId: device.id,
          actorRole: 'device',
          patientPseudonym: NO_PATIENT,
          resourceType: 'device',
          resourceId: device.id,
          outcome: 'device:push_token_registered',
        });
      });
      return reply.status(204).send();
    },
  );
}
