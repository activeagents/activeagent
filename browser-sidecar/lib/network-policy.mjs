import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';

// IPv4 ranges that are not the public internet: this host, private networks,
// carrier-grade NAT, loopback, link-local (cloud metadata lives there),
// benchmarking, multicast and reserved.
const PRIVATE_IPV4 = [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  ['172.16.0.0', 12],
  ['192.0.0.0', 24],
  ['192.168.0.0', 16],
  ['198.18.0.0', 15],
  ['224.0.0.0', 4],
  ['240.0.0.0', 4],
];

function ipv4ToInt(address) {
  return address.split('.').reduce((total, part) => total * 256 + Number(part), 0);
}

function inIpv4Range(address, [base, bits]) {
  const size = 2 ** (32 - bits);
  return Math.floor(ipv4ToInt(address) / size) === Math.floor(ipv4ToInt(base) / size);
}

// The eight 16-bit groups of an IPv6 address, an embedded dotted IPv4 tail
// included, or null when it is not one.
function ipv6Groups(address) {
  let text = address.toLowerCase().replace(/%.*$/, '');
  const dotted = /(\d+\.\d+\.\d+\.\d+)$/.exec(text);
  if (dotted) {
    const value = ipv4ToInt(dotted[1]);
    text = `${text.slice(0, -dotted[1].length)}${(value >>> 16).toString(16)}:${(value & 0xffff).toString(16)}`;
  }

  const halves = text.split('::');
  if (halves.length > 2) return null;
  const head = halves[0] === '' ? [] : halves[0].split(':');
  const tail = halves.length === 2 && halves[1] !== '' ? halves[1].split(':') : [];
  const missing = 8 - head.length - tail.length;
  if (halves.length === 1 ? missing !== 0 : missing < 1) return null;

  const groups = [...head, ...Array(halves.length === 2 ? missing : 0).fill('0'), ...tail].map((group) => parseInt(group, 16));
  return groups.every((group) => Number.isInteger(group) && group >= 0 && group <= 0xffff) ? groups : null;
}

function groupsToIpv4(high, low) {
  return [high >> 8, high & 255, low >> 8, low & 255].join('.');
}

function isPrivateIpv6(address) {
  const groups = ipv6Groups(address);
  if (!groups) return false;

  const [first] = groups;
  const leadingZeros = groups.findIndex((group) => group !== 0);
  if (leadingZeros === -1) return true; // ::
  if (leadingZeros === 7 && groups[7] === 1) return true; // ::1
  // ::ffff:a.b.c.d (mapped) and ::a.b.c.d (compatible) carry an IPv4 address,
  // and so does 64:ff9b::a.b.c.d (NAT64).
  const mapped = leadingZeros >= 5 && (groups[5] === 0xffff || (leadingZeros >= 6 && groups[5] === 0));
  const nat64 = first === 0x64 && groups[1] === 0xff9b && groups.slice(2, 6).every((group) => group === 0);
  if (mapped || nat64) return isPrivateAddress(groupsToIpv4(groups[6], groups[7]));

  // fc00::/7 unique local, fe80::/10 link-local, fec0::/10 site-local, ff00::/8 multicast.
  return (first & 0xfe00) === 0xfc00 || (first & 0xffc0) === 0xfe80 || (first & 0xffc0) === 0xfec0 || (first & 0xff00) === 0xff00;
}

/**
 * Whether `address`, an IP literal, is loopback, link-local, private or
 * otherwise not on the public internet. A name that is not an IP is false.
 *
 * @param {string} address
 * @returns {boolean}
 */
export function isPrivateAddress(address) {
  const bare = address.replace(/^\[|\]$/g, '');
  const family = isIP(bare);
  if (family === 4) return PRIVATE_IPV4.some((range) => inIpv4Range(bare, range));
  return family === 6 && isPrivateIpv6(bare);
}

/**
 * Whether `hostname` names this machine or a local network by name alone.
 *
 * @param {string} hostname
 * @returns {boolean}
 */
export function isLocalName(hostname) {
  const name = hostname.toLowerCase().replace(/\.$/, '');
  return name === 'localhost' || name.endsWith('.localhost') || name.endsWith('.local') || name.endsWith('.internal');
}

async function resolveAll(hostname) {
  const records = await lookup(hostname, { all: true, verbatim: true });
  return records.map((record) => record.address);
}

/**
 * Used to decide what the browser may load. The sandbox app's own origin is
 * always allowed. A top-level navigation anywhere else is refused, and so is
 * any request to a loopback, link-local or private address, whether the URL
 * names the address or a host name that resolves to one.
 */
export class NetworkPolicy {
  /**
   * @param {object} options
   * @param {string} options.appOrigin the sandbox app's origin
   * @param {(hostname: string) => Promise<string[]>} [options.resolve] how host names are resolved
   * @param {number} [options.cacheMs] how long a resolution is reused
   */
  constructor({ appOrigin, resolve = resolveAll, cacheMs = 60_000 }) {
    this.appOrigin = appOrigin;
    this.resolve = resolve;
    this.cacheMs = cacheMs;
    this.resolved = new Map();
  }

  /**
   * Returns `url` as the absolute URL a navigation would open, and why it
   * may not, if it may not. A path ("/login") is resolved against the app.
   *
   * @param {string} url
   * @returns {{ url: string, refusal: string | null }}
   */
  navigationTarget(url) {
    const text = String(url ?? '').trim();
    if (text === 'about:blank') return { url: text, refusal: null };

    let target;
    try {
      target = text.startsWith('/') && !text.startsWith('//') ? new URL(text, this.appOrigin) : new URL(text);
    } catch {
      return { url: text, refusal: this.refusalMessage(text) };
    }
    if (target.origin !== this.appOrigin) return { url: text, refusal: this.refusalMessage(text) };

    return { url: target.toString(), refusal: null };
  }

  refusalMessage(url) {
    return `Navigation to ${url} was refused: this browser may only open pages of the sandbox app at ${this.appOrigin}`;
  }

  /**
   * Whether the browser may make a request to `url`.
   *
   * @param {string} url
   * @param {{ topLevelNavigation?: boolean }} [options]
   * @returns {Promise<boolean>}
   */
  async allows(url, { topLevelNavigation = false } = {}) {
    let target;
    try {
      target = new URL(url);
    } catch {
      return false;
    }

    if (target.protocol !== 'http:' && target.protocol !== 'https:' && target.protocol !== 'ws:' && target.protocol !== 'wss:') {
      return !topLevelNavigation || url === 'about:blank';
    }
    if (this.sameOriginAsApp(target)) return true;
    if (topLevelNavigation) return false;

    const hostname = target.hostname.replace(/^\[|\]$/g, '');
    if (isPrivateAddress(hostname) || isLocalName(hostname)) return false;
    if (isIP(hostname)) return true;

    return !(await this.resolvesPrivately(hostname));
  }

  // A WebSocket URL is the app's when it names the app's host and port.
  sameOriginAsApp(target) {
    if (target.origin === this.appOrigin) return true;
    if (target.protocol !== 'ws:' && target.protocol !== 'wss:') return false;

    const http = new URL(target.toString());
    http.protocol = target.protocol === 'ws:' ? 'http:' : 'https:';
    return http.origin === this.appOrigin;
  }

  async resolvesPrivately(hostname) {
    const cached = this.resolved.get(hostname);
    if (cached && cached.until > Date.now()) return cached.private;

    let addresses = [];
    try {
      addresses = await this.resolve(hostname);
    } catch {
      // A name that does not resolve cannot be loaded either.
    }
    const verdict = addresses.some((address) => isPrivateAddress(address));
    this.resolved.set(hostname, { private: verdict, until: Date.now() + this.cacheMs });
    return verdict;
  }
}
