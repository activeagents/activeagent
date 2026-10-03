import { createHash, timingSafeEqual } from 'node:crypto';

const LOOPBACK_NAMES = ['127.0.0.1', 'localhost', '[::1]'];

function hostName(host) {
  return host.includes(':') && !host.startsWith('[') ? `[${host}]` : host;
}

/**
 * Returns the Host header values a request to the sidecar may carry: the
 * address it listens on and, when that is loopback or every interface, the
 * loopback names, each with the port; and `extra` as given (the names the
 * sidecar is reached by inside a container network).
 *
 * @param {string} host the listening address
 * @param {number} port the listening port
 * @param {string[]} extra Host values to accept as given
 * @returns {Set<string>}
 */
export function acceptedHosts(host, port, extra = []) {
  const names = new Set([hostName(host.toLowerCase())]);
  if (['127.0.0.1', 'localhost', '::1', '0.0.0.0', '::'].includes(host)) {
    for (const name of LOOPBACK_NAMES) names.add(name);
  }
  names.delete('0.0.0.0');
  names.delete('[::]');

  const accepted = new Set([...names].map((name) => `${name}:${port}`));
  for (const value of extra) accepted.add(value.toLowerCase());
  return accepted;
}

function digest(value) {
  return createHash('sha256').update(value).digest();
}

function bearerMatches(header, token) {
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header ?? '');
  return match !== null && timingSafeEqual(digest(match[1]), digest(token));
}

/**
 * Checks one HTTP request, or WebSocket upgrade, before anything else reads
 * it. A request must name an accepted Host, which defeats DNS rebinding,
 * carry no Origin unless that origin is allowed (a page in a browser always
 * sends one), and carry the bearer token.
 *
 * @param {import('node:http').IncomingMessage} request
 * @param {{ token: string, hosts: Set<string>, origins?: Set<string> }} rules
 * @returns {{ status: number, message: string } | null} the refusal, or null to proceed
 */
export function refusal(request, { token, hosts, origins = new Set() }) {
  const host = (request.headers.host ?? '').toLowerCase();
  if (!hosts.has(host)) return { status: 403, message: 'Host not allowed' };

  const origin = request.headers.origin;
  if (origin !== undefined && !origins.has(origin)) return { status: 403, message: 'Origin not allowed' };

  if (!bearerMatches(request.headers.authorization, token)) return { status: 401, message: 'Missing or invalid bearer token' };

  return null;
}
