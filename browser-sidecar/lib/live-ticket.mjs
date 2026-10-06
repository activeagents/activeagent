import { createHmac, timingSafeEqual } from 'node:crypto';

// The dashboard derives the same key from the same token, so a ticket made
// for one browser start is useless against any other.
export const TICKET_CONTEXT = 'activeagents/browser-live-ticket/v1';
export const MODES = ['view', 'control'];
// The longest a ticket may live, whatever it claims, and how far ahead of
// this machine's clock the dashboard's may be.
export const MAX_TICKET_SECONDS = 60;
const CLOCK_SKEW_SECONDS = 5;
const MAX_TICKET_CHARS = 2048;
const MAX_NAME_CHARS = 80;
const TICKET = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;
const TICKET_ID = /^[A-Za-z0-9_-]{16,64}$/;

/**
 * Returns the key tickets are signed with: an HMAC-SHA256 of TICKET_CONTEXT
 * under the browser's bearer token.
 *
 * @param {string} token
 * @returns {Buffer}
 */
export function ticketKey(token) {
  return createHmac('sha256', token).update(TICKET_CONTEXT).digest();
}

function sign(key, payload) {
  return createHmac('sha256', key).update(payload).digest();
}

/**
 * Returns a ticket for `claims`, signed with `key`, in the form the
 * dashboard issues: base64url(JSON claims), a dot, base64url(HMAC-SHA256 of
 * that first part). Used by tests; the dashboard issues the real ones.
 *
 * @param {Buffer} key see ticketKey
 * @param {object} claims
 * @returns {string}
 */
export function signTicket(key, claims) {
  const payload = Buffer.from(JSON.stringify(claims)).toString('base64url');
  return `${payload}.${sign(key, payload).toString('base64url')}`;
}

function nullableString(value, limit) {
  if (value === null || value === undefined) return null;
  return typeof value === 'string' ? value.slice(0, limit) : undefined;
}

/**
 * Used to check the tickets a viewer presents. A ticket is accepted once:
 * signed with this browser's key, naming this sandbox session and a mode,
 * issued for at most MAX_TICKET_SECONDS, unexpired, and not seen before.
 *
 * Claims:
 *   v     1
 *   sid   the sandbox session
 *   sub   who it was issued to, or null when the dashboard has no signed-in user
 *   name  their name to show other viewers, or null
 *   mode  "view" (watch) or "control" (take over)
 *   iat   when it was issued, in epoch seconds
 *   exp   when it expires, in epoch seconds
 *   jti   its unique id
 */
export class TicketVerifier {
  /**
   * @param {object} options
   * @param {Buffer} options.key see ticketKey
   * @param {string} options.sessionId the sandbox session this browser belongs to
   * @param {() => number} [options.now] epoch milliseconds
   */
  constructor({ key, sessionId, now = Date.now }) {
    this.key = key;
    this.sessionId = sessionId;
    this.now = now;
    this.used = new Map();
  }

  /**
   * Checks `ticket` and, when it is valid, marks it used.
   *
   * @param {unknown} ticket
   * @returns {{ claims: { sub: string|null, name: string|null, mode: string, exp: number } } | { refusal: string }}
   */
  verify(ticket) {
    if (typeof ticket !== 'string' || ticket.length > MAX_TICKET_CHARS || !TICKET.test(ticket)) return { refusal: 'malformed' };

    const [payload, signature] = ticket.split('.');
    const given = Buffer.from(signature, 'base64url');
    const expected = sign(this.key, payload);
    if (given.length !== expected.length || !timingSafeEqual(given, expected)) return { refusal: 'bad signature' };

    let claims;
    try {
      claims = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    } catch {
      return { refusal: 'malformed' };
    }
    if (!claims || typeof claims !== 'object' || claims.v !== 1) return { refusal: 'malformed' };
    if (claims.sid !== this.sessionId) return { refusal: 'another sandbox' };
    if (!MODES.includes(claims.mode)) return { refusal: 'unknown mode' };

    const { iat, exp, jti } = claims;
    const now = this.now() / 1000;
    if (!Number.isInteger(iat) || !Number.isInteger(exp) || exp <= iat || exp - iat > MAX_TICKET_SECONDS) return { refusal: 'bad lifetime' };
    if (iat > now + CLOCK_SKEW_SECONDS) return { refusal: 'issued in the future' };
    if (exp <= now) return { refusal: 'expired' };
    if (typeof jti !== 'string' || !TICKET_ID.test(jti)) return { refusal: 'malformed' };

    const sub = nullableString(claims.sub, 256);
    const name = nullableString(claims.name, MAX_NAME_CHARS);
    if (sub === undefined || name === undefined) return { refusal: 'malformed' };

    this.forgetExpired(now);
    if (this.used.has(jti)) return { refusal: 'already used' };
    this.used.set(jti, exp);

    return { claims: { sub, name, mode: claims.mode, exp } };
  }

  forgetExpired(now) {
    for (const [jti, exp] of this.used) {
      if (exp <= now) this.used.delete(jti);
    }
  }
}
