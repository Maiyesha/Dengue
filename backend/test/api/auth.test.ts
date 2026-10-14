import { randomUUID } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { generateKeyPair } from 'jose';
import { requireUser, requireDevice, requireUserOrDevice, actorOf, type Actor } from '../../src/auth';
import { withRls } from '../../src/db';
import { audit } from '../../src/audit';
import { getTestPool } from '../pg';
import { seedFixtures, clearFixtures, SITE_A, SITE_B, PATIENT_A } from '../fixtures';
import { buildTestApp, tokenFor, deviceTokenFor, deviceTokenSigner, bearer } from './helpers';

const pool = getTestPool();
let app: FastifyInstance;

const DEVICE_ID = '00000000-0000-4000-c000-00000000000a';

/** Inserts a scan for PATIENT_A then audits with the given event type, in one withRls call. */
async function scanThenAudit(actor: Actor, clientSessionId: string, eventType: string) {
  await withRls(pool, actor, async (c) => {
    await c.query(
      `INSERT INTO scans(client_session_id, patient_id, site_id, captured_at, protocol_version)
       VALUES ($1, $2, $3, now(), 'p1')`,
      [clientSessionId, PATIENT_A, actor.siteId],
    );
    await audit(c, {
      eventType,
      actorId: actor.id,
      actorRole: actor.roles[0],
      patientPseudonym: 'ps-rls-a',
      resourceType: 'scan',
      resourceId: clientSessionId,
      outcome: 'success',
    });
  });
}

beforeAll(async () => {
  await seedFixtures(pool);
  ({ app } = await buildTestApp((a) => {
    a.get('/t/nurse', { preHandler: requireUser('nurse_operator') }, async (req) => actorOf(req));
    a.get('/t/device', { preHandler: requireDevice() }, async (req) => actorOf(req));
    a.get('/t/either', { preHandler: requireUserOrDevice('nurse_operator') }, async (req) => actorOf(req));
    a.post('/t/scan-audit', { preHandler: requireUser('nurse_operator') }, async (req) => {
      const { csid, eventType } = req.body as { csid: string; eventType: string };
      await scanThenAudit(actorOf(req), csid, eventType);
      return { ok: true };
    });
  }));
});

afterAll(async () => {
  await app.close();
  await pool.query(`DELETE FROM scans WHERE patient_id = $1 AND protocol_version = 'p1' AND id NOT IN
                      ('00000000-0000-4000-b000-00000000000a','00000000-0000-4000-b000-00000000000b')`, [PATIENT_A]);
  await clearFixtures(pool);
  await pool.end();
});

const get = (url: string, headers: Record<string, string> = {}) => app.inject({ method: 'GET', url, headers });

describe('requireUser', () => {
  it('no token → 401', async () => {
    const r = await get('/t/nurse');
    expect(r.statusCode).toBe(401);
    expect(r.json().error.code).toBe('DS_AUTH_001');
  });

  it('non-Bearer / malformed header → 401', async () => {
    expect((await get('/t/nurse', { authorization: 'Basic abc' })).statusCode).toBe(401);
    expect((await get('/t/nurse', { authorization: 'Bearer not.a.jwt' })).statusCode).toBe(401);
  });

  it('expired token → 401', async () => {
    const t = await tokenFor('nurse_operator', SITE_A, { issuedAt: -1000, expiresIn: -100 });
    const r = await get('/t/nurse', bearer(t));
    expect(r.statusCode).toBe(401);
    expect(r.json().error.code).toBe('DS_AUTH_001');
  });

  it('token signed by another key → 401', async () => {
    const other = await generateKeyPair('RS256');
    const t = await tokenFor('nurse_operator', SITE_A, { key: other.privateKey });
    expect((await get('/t/nurse', bearer(t))).statusCode).toBe(401);
  });

  it('wrong issuer → 401', async () => {
    const t = await tokenFor('nurse_operator', SITE_A, { issuer: 'https://evil' });
    expect((await get('/t/nurse', bearer(t))).statusCode).toBe(401);
  });

  it('token older than 15 min (iat) → 401 even if exp is later', async () => {
    const t = await tokenFor('nurse_operator', SITE_A, { issuedAt: -3600, expiresIn: 3600 });
    expect((await get('/t/nurse', bearer(t))).statusCode).toBe(401);
  });

  it('unknown role claim → 401', async () => {
    const t = await tokenFor('superhero', SITE_A);
    expect((await get('/t/nurse', bearer(t))).statusCode).toBe(401);
  });

  it('user JWT claiming the device role or device audience → 401/403, never accepted', async () => {
    const t1 = await tokenFor('device', SITE_A);
    expect((await get('/t/nurse', bearer(t1))).statusCode).toBe(401);
    const t2 = await tokenFor('nurse_operator', SITE_A, { audience: 'device-upload' });
    expect([401, 403]).toContain((await get('/t/nurse', bearer(t2))).statusCode);
  });

  it('researcher on nurse route → 403', async () => {
    const t = await tokenFor('researcher');
    const r = await get('/t/nurse', bearer(t));
    expect(r.statusCode).toBe(403);
    expect(r.json().error.code).toBe('DS_AUTH_002');
  });

  it('nurse → 200 with actor from claims', async () => {
    const t = await tokenFor('nurse_operator', SITE_A);
    const r = await get('/t/nurse', bearer(t));
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({
      kind: 'user', id: 'rls-nurse_operator', roles: ['nurse_operator'], siteId: SITE_A, deidentify: false,
    });
  });

  it('device token on GET /v1/patients/lookup → 403', async () => {
    const t = await deviceTokenFor(DEVICE_ID, SITE_A);
    const r = await get('/v1/patients/lookup?participant_code=DS-RLSA-00001', bearer(t));
    expect(r.statusCode).toBe(403);
    expect(r.json().error.code).toBe('DS_AUTH_002');
  });
});

describe('requireDevice', () => {
  it('device token → actor kind device with roles [device]', async () => {
    const t = await deviceTokenFor(DEVICE_ID, SITE_A);
    const r = await get('/t/device', bearer(t));
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ kind: 'device', id: DEVICE_ID, roles: ['device'], siteId: SITE_A, deidentify: false });
  });

  it('user token on device route → 403; garbage → 401; none → 401', async () => {
    expect((await get('/t/device', bearer(await tokenFor('nurse_operator', SITE_A)))).statusCode).toBe(403);
    expect((await get('/t/device', bearer('garbage'))).statusCode).toBe(401);
    expect((await get('/t/device')).statusCode).toBe(401);
  });

  it('requireUserOrDevice accepts both, rejects other roles', async () => {
    expect((await get('/t/either', bearer(await deviceTokenFor(DEVICE_ID, SITE_A)))).json().kind).toBe('device');
    expect((await get('/t/either', bearer(await tokenFor('nurse_operator', SITE_A)))).json().kind).toBe('user');
    expect((await get('/t/either', bearer(await tokenFor('admin')))).statusCode).toBe(403);
  });
});

describe('device status and verifier routing', () => {
  it('device token for an unknown (never enrolled) device → 401 DS_DEVICE_001', async () => {
    const t = await deviceTokenSigner.sign({ device_id: randomUUID(), site_id: SITE_A });
    const r = await get('/t/device', bearer(t));
    expect(r.statusCode).toBe(401);
    expect(r.json().error.code).toBe('DS_DEVICE_001');
  });

  it('revoked device → 401 DS_DEVICE_001 on device and either routes', async () => {
    const id = randomUUID();
    const t = await deviceTokenFor(id, SITE_A);
    expect((await get('/t/device', bearer(t))).statusCode).toBe(200);
    await pool.query(`UPDATE devices SET status='revoked' WHERE id=$1`, [id]);
    for (const url of ['/t/device', '/t/either']) {
      const r = await get(url, bearer(t));
      expect(r.statusCode).toBe(401);
      expect(r.json().error.code).toBe('DS_DEVICE_001');
    }
  });

  it('token site_id differing from the enrolled device site → 401 DS_DEVICE_001', async () => {
    const id = randomUUID();
    await deviceTokenFor(id, SITE_A); // enrols in site A
    const forged = await deviceTokenSigner.sign({ device_id: id, site_id: SITE_B });
    expect((await get('/t/device', bearer(forged))).json().error.code).toBe('DS_DEVICE_001');
  });

  it('verifier is chosen by aud: device-aud token signed with the user key → 401; user token never tried as device', async () => {
    const t = await tokenFor('nurse_operator', SITE_A, { audience: 'device-upload' });
    expect((await get('/t/either', bearer(t))).statusCode).toBe(401);
    const u = await tokenFor('nurse_operator', SITE_A, { audience: 'something-else' });
    expect((await get('/t/device', bearer(u))).statusCode).toBe(403);
  });
});

describe('withRls', () => {
  it('rejects hand-built actors with unknown roles, roles containing a comma, or no roles', async () => {
    for (const roles of [['superuser'], ['nurse_operator,admin'], ['clinician', 'admin,x'], []]) {
      const actor = { kind: 'user', id: 'u', roles, siteId: SITE_A, deidentify: false } as unknown as Actor;
      await expect(withRls(pool, actor, async () => 'ran')).rejects.toThrow(/withRls/);
    }
    const ok: Actor = { kind: 'user', id: 'u', roles: ['system_agent'], siteId: SITE_A, deidentify: true };
    expect(await withRls(pool, ok, async () => 'ran')).toBe('ran');
  });

  it('withRls sets app.site_id visible to current_setting', async () => {
    const actor: Actor = { kind: 'user', id: 'rls-nurse_operator', roles: ['nurse_operator'], siteId: SITE_A, deidentify: true };
    const row = await withRls(pool, actor, async (c) =>
      (await c.query(`SELECT current_setting('app.site_id') AS site, current_setting('app.user_id') AS uid,
                             current_setting('app.roles') AS roles, current_setting('app.deidentify') AS deid,
                             current_user AS cu, current_setting('transaction_isolation') AS iso`)).rows[0]);
    expect(row).toEqual({ site: SITE_A, uid: 'rls-nurse_operator', roles: 'nurse_operator', deid: 'true', cu: 'app_api', iso: 'read committed' });
  });

  it('device actor runs with app.roles = device and sees only its own site', async () => {
    const actor: Actor = { kind: 'device', id: DEVICE_ID, roles: ['device'], siteId: SITE_A, deidentify: false };
    const r = await withRls(pool, actor, async (c) => ({
      roles: (await c.query(`SELECT current_setting('app.roles') AS r`)).rows[0].r,
      sites: (await c.query('SELECT DISTINCT site_id FROM scans')).rows.map((x) => x.site_id),
    }));
    expect(r.roles).toBe('device');
    expect(r.sites).toEqual([SITE_A]);
  });

  it('settings and role do not leak to the next use of the pooled connection', async () => {
    const actor: Actor = { kind: 'user', id: 'u', roles: ['clinician'], siteId: SITE_B, deidentify: false };
    await withRls(pool, actor, async () => undefined);
    const clients = await Promise.all(Array.from({ length: 5 }, () => pool.connect()));
    try {
      for (const c of clients) {
        const r = (await c.query(`SELECT COALESCE(current_setting('app.site_id', true), '') AS s, current_user AS cu`)).rows[0];
        expect(r.s).toBe('');
        expect(r.cu).not.toBe('app_api');
      }
    } finally {
      clients.forEach((c) => c.release());
    }
  });

  it('a site-less actor sees zero scans (fails closed)', async () => {
    const actor: Actor = { kind: 'user', id: 'u', roles: ['nurse_operator'], deidentify: false };
    const n = await withRls(pool, actor, async (c) => (await c.query('SELECT count(*)::int AS n FROM scans')).rows[0].n);
    expect(n).toBe(0);
  });

  it('rolls back when fn throws', async () => {
    const csid = randomUUID();
    const actor: Actor = { kind: 'user', id: 'u', roles: ['nurse_operator'], siteId: SITE_A, deidentify: false };
    await expect(withRls(pool, actor, async (c) => {
      await c.query(`INSERT INTO scans(client_session_id, patient_id, site_id, captured_at, protocol_version)
                     VALUES ($1,$2,$3,now(),'p1')`, [csid, PATIENT_A, SITE_A]);
      throw new Error('boom');
    })).rejects.toThrow('boom');
    expect((await pool.query('SELECT 1 FROM scans WHERE client_session_id=$1', [csid])).rowCount).toBe(0);
  });

  it('refuses to report success when fn swallowed a DB error (aborted tx)', async () => {
    const csid = randomUUID();
    const actor: Actor = { kind: 'user', id: 'u', roles: ['nurse_operator'], siteId: SITE_A, deidentify: false };
    await expect(withRls(pool, actor, async (c) => {
      await c.query(`INSERT INTO scans(client_session_id, patient_id, site_id, captured_at, protocol_version)
                     VALUES ($1,$2,$3,now(),'p1')`, [csid, PATIENT_A, SITE_A]);
      await c.query('SELECT 1/0').catch(() => undefined);
      return 'ok';
    })).rejects.toThrow();
    expect((await pool.query('SELECT 1 FROM scans WHERE client_session_id=$1', [csid])).rowCount).toBe(0);
  });
});

describe('audit', () => {
  const post = async (csid: string, eventType: string) =>
    app.inject({
      method: 'POST', url: '/t/scan-audit',
      headers: bearer(await tokenFor('nurse_operator', SITE_A)),
      payload: { csid, eventType },
    });

  it('writes a hashed audit row in the same transaction as the business insert', async () => {
    const csid = randomUUID();
    const r = await post(csid, 'clinician_action');
    expect(r.statusCode).toBe(200);
    expect((await pool.query('SELECT 1 FROM scans WHERE client_session_id=$1', [csid])).rowCount).toBe(1);
    const a = await pool.query(
      `SELECT actor_id_hash, actor_role, patient_pseudonym, outcome FROM clinical_audit_log WHERE resource_id=$1`, [csid]);
    expect(a.rows).toEqual([{
      actor_id_hash: (await import('node:crypto')).createHash('sha256').update('rls-nurse_operator').digest('hex'),
      actor_role: 'nurse_operator', patient_pseudonym: 'ps-rls-a', outcome: 'success',
    }]);
    expect((await pool.query('SELECT audit_verify_chain() AS v')).rows[0].v).toBeNull();
  });

  it('audit failure rolls back the business insert', async () => {
    const csid = randomUUID();
    const r = await post(csid, 'not_a_real_event_type');
    expect(r.statusCode).toBe(403);
    expect(r.json().error.code).toBe('DS_AUD_001');
    expect((await pool.query('SELECT 1 FROM scans WHERE client_session_id=$1', [csid])).rowCount).toBe(0);
    expect((await pool.query('SELECT 1 FROM clinical_audit_log WHERE resource_id=$1', [csid])).rowCount).toBe(0);
  });
});

