import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';

// How many client tokens may be live at once, and the longest a label may be.
export const MAX_CLIENT_TOKENS = 32;
export const MAX_LABEL_LENGTH = 120;
// How long a client token lasts unless revoked first.
export const DEFAULT_CLIENT_TOKEN_TTL_MS = 6 * 60 * 60_000;

function digest(value) {
  return createHash('sha256').update(value).digest();
}

function cleanLabel(label) {
  if (typeof label !== 'string') return null;
  const clean = label.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, MAX_LABEL_LENGTH);
  return clean === '' ? null : clean;
}

/**
 * Used to hand out scoped, revocable tokens for the MCP endpoint, so a client
 * that runs other people's code (Claude Code, whose shell commands inherit
 * its environment) never holds the master token, and loses access the
 * moment its turn ends.
 *
 * A client token may only call /mcp. Minting and revoking one, and every
 * other endpoint, take the master token (see http-server).
 *
 * Each token carries a label ("Claude Code · turn 42"), which the gateway
 * tags that client's tool calls with: the live view names who is waiting
 * for control by it.
 */
export class ClientTokens {
  /**
   * @param {object} [options]
   * @param {number} [options.max]
   * @param {number} [options.ttlMs]
   * @param {() => number} [options.now]
   */
  constructor({ max = MAX_CLIENT_TOKENS, ttlMs = DEFAULT_CLIENT_TOKEN_TTL_MS, now = Date.now } = {}) {
    this.max = max;
    this.ttlMs = ttlMs;
    this.now = now;
    this.tokens = new Map();
  }

  /**
   * Mints a token.
   *
   * @param {{ label?: string }} [request]
   * @returns {{ id: string, token: string, label: string|null, expires_at: string }}
   * @throws {Error} with status 429 when too many are live
   */
  mint({ label } = {}) {
    this.prune();
    if (this.tokens.size >= this.max) throw Object.assign(new Error('Too many client tokens are live'), { status: 429 });

    const id = randomUUID();
    const token = `cl_${randomBytes(32).toString('base64url')}`;
    const entry = { id, digest: digest(token), label: cleanLabel(label), expiresAt: this.now() + this.ttlMs };
    this.tokens.set(id, entry);
    return { id, token, label: entry.label, expires_at: new Date(entry.expiresAt).toISOString() };
  }

  /**
   * @param {string} id
   * @returns {boolean} whether there was such a token
   */
  revoke(id) {
    return this.tokens.delete(id);
  }

  /**
   * The live client `token` matches, or null.
   *
   * @param {string} token
   * @returns {{ id: string, label: string|null } | null}
   */
  match(token) {
    if (typeof token !== 'string' || !token.startsWith('cl_')) return null;
    this.prune();
    const presented = digest(token);
    for (const entry of this.tokens.values()) {
      if (timingSafeEqual(presented, entry.digest)) return { id: entry.id, label: entry.label };
    }
    return null;
  }

  prune() {
    const now = this.now();
    for (const [id, entry] of this.tokens) if (entry.expiresAt <= now) this.tokens.delete(id);
  }

  get size() {
    this.prune();
    return this.tokens.size;
  }
}
