// JWT authentication and route-level RBAC guards (Fastify preHandlers).
//
// User access tokens: RS256, issuer = deps.jwtIssuer, <= 15 min old, claims
//   sub (= app_users.id), roles (non-empty array of user roles), site_id?, deidentify?, jti.
// Device tokens: verified by deps.deviceTokenSigner (aud "device-upload"); actor roles ['device'].
//   The verifier is chosen by the token's UNVERIFIED `aud` (decodeJwt): aud contains
//   "device-upload" -> device verifier only; otherwise -> user verifier only. There is no
//   try-one-then-the-other fallback, so a token is only ever checked against one key.
//   Every device-authenticated request re-reads the devices row (as the device itself, own row
//   only): unknown device, site mismatch, or status 'revoked' -> 401 DS_DEVICE_001.
//
// 401 DS_AUTH_001: missing / malformed / invalid / expired credentials.
// 401 DS_DEVICE_001: device not enrolled or revoked.
// 403 DS_AUTH_002: valid credentials whose kind or role is not allowed on this route
//                  (incl. a device token on a user-only route).
import { decodeJwt, jwtVerify, type JWTPayload } from 'jose';
import type { FastifyRequest, preHandlerAsyncHookHandler } from 'fastify';
import { ApiError } from './errors';
import { withRls } from './db';

export const USER_ROLES = [
  'nurse_operator',
  'clinician',
  'researcher',
  'biostatistician',
  'admin',
  'regulatory_reviewer',
  'system_agent',
] as const;
export type UserRole = (typeof USER_ROLES)[number];
export type AppRole = UserRole | 'device';

export const DEVICE_AUDIENCE = 'device-upload';
const ACCESS_TOKEN_MAX_AGE = '15m';

export interface Actor {
  kind: 'user' | 'device';
  id: string;
  roles: AppRole[];
  siteId?: string;
  deidentify: boolean;
}

declare module 'fastify' {
  interface FastifyRequest {
    actor: Actor | null;
  }
}

const unauthenticated = () => new ApiError(401, 'DS_AUTH_001', 'Authentication required');
const forbidden = () => new ApiError(403, 'DS_AUTH_002', 'Not permitted for this route');

/** The authenticated actor; throws 401 if no guard ran (programming error fails closed). */
export function actorOf(req: FastifyRequest): Actor {
  if (!req.actor) throw unauthenticated();
  return req.actor;
}

function bearerToken(req: FastifyRequest): string {
  const h = req.headers.authorization;
  if (typeof h !== 'string') throw unauthenticated();
  const m = /^Bearer ([A-Za-z0-9._~+/=-]+)$/.exec(h.trim());
  if (!m) throw unauthenticated();
  return m[1];
}

const isUserRole = (r: unknown): r is UserRole => typeof r === 'string' && (USER_ROLES as readonly string[]).includes(r);

function userActorFrom(p: JWTPayload): Actor {
  const aud = p.aud === undefined ? [] : Array.isArray(p.aud) ? p.aud : [p.aud];
  if (aud.includes(DEVICE_AUDIENCE)) throw forbidden(); // a device token is never a user token
  const roles = p.roles;
  if (typeof p.sub !== 'string' || p.sub === '' || typeof p.jti !== 'string') throw unauthenticated();
  if (!Array.isArray(roles) || roles.length === 0 || !roles.every(isUserRole)) throw unauthenticated();
  if (p.site_id !== undefined && (typeof p.site_id !== 'string' || p.site_id === '')) throw unauthenticated();
  if (p.deidentify !== undefined && typeof p.deidentify !== 'boolean') throw unauthenticated();
  return {
    kind: 'user',
    id: p.sub,
    roles: [...new Set(roles)],
    ...(p.site_id !== undefined ? { siteId: p.site_id as string } : {}),
    // Absent claim => de-identified view (fail closed).
    deidentify: p.deidentify === undefined ? true : (p.deidentify as boolean),
  };
}

const deviceRevoked = () => new ApiError(401, 'DS_DEVICE_001', 'Device is not enrolled or has been revoked');

function audiencesOf(token: string): string[] {
  let p: JWTPayload;
  try {
    p = decodeJwt(token); // UNVERIFIED: used only to pick the verifier
  } catch {
    throw unauthenticated();
  }
  return p.aud === undefined ? [] : Array.isArray(p.aud) ? p.aud : [p.aud];
}

async function authenticateUser(req: FastifyRequest, token: string): Promise<Actor> {
  const deps = req.server.deps;
  let payload: JWTPayload;
  try {
    ({ payload } = await jwtVerify(token, deps.jwtVerifyKey, {
      issuer: deps.jwtIssuer,
      algorithms: ['RS256'],
      currentDate: deps.now(),
      maxTokenAge: ACCESS_TOKEN_MAX_AGE,
      requiredClaims: ['sub', 'exp', 'iat', 'jti'],
    }));
  } catch {
    throw unauthenticated();
  }
  return userActorFrom(payload);
}

async function authenticateDevice(req: FastifyRequest, token: string): Promise<Actor> {
  const deps = req.server.deps;
  let claims;
  try {
    claims = await deps.deviceTokenSigner.verify(token);
  } catch {
    throw unauthenticated();
  }
  if (typeof claims?.device_id !== 'string' || claims.device_id === '' ||
      typeof claims.site_id !== 'string' || claims.site_id === '') {
    throw unauthenticated();
  }
  const actor: Actor = { kind: 'device', id: claims.device_id, roles: ['device'], siteId: claims.site_id, deidentify: false };
  // Revocation check on every request. RLS (devices_select_self) lets a device read only its
  // own row, and only when app.site_id matches the row's site.
  const row = await withRls(deps.pool, actor, async (c) =>
    (await c.query<{ status: string }>('SELECT status FROM devices WHERE id::text = $1', [actor.id])).rows[0]);
  if (!row || row.status !== 'active') throw deviceRevoked();
  return actor;
}

/** Verifies the bearer token with exactly one verifier, chosen by its (unverified) audience. */
async function authenticate(req: FastifyRequest): Promise<Actor> {
  const token = bearerToken(req);
  return audiencesOf(token).includes(DEVICE_AUDIENCE)
    ? authenticateDevice(req, token)
    : authenticateUser(req, token);
}

function guard(allow: (a: Actor) => boolean): preHandlerAsyncHookHandler {
  return async function (req) {
    req.actor = null;
    const actor = await authenticate(req);
    if (!allow(actor)) throw forbidden();
    req.actor = actor;
  };
}

const userWith = (roles: UserRole[]) => (a: Actor) =>
  a.kind === 'user' && a.roles.some((r) => (roles as AppRole[]).includes(r));

/** User token with at least one of `roles`. Device tokens get 403. */
export function requireUser(...roles: UserRole[]): preHandlerAsyncHookHandler {
  if (roles.length === 0) throw new Error('requireUser needs at least one role');
  return guard(userWith(roles));
}

/** Device token only (aud "device-upload"). User tokens get 403. */
export function requireDevice(): preHandlerAsyncHookHandler {
  return guard((a) => a.kind === 'device');
}

/** Either a device token or a user token with one of `roles` (artefact routes, GET /scans/:id). */
export function requireUserOrDevice(...roles: UserRole[]): preHandlerAsyncHookHandler {
  const user = userWith(roles);
  return guard((a) => a.kind === 'device' || user(a));
}
