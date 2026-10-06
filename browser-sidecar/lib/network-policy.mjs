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

function bare(hostname) {
  return hostname.toLowerCase().replace(/^\[|\]$/g, '');
}

function defaultPort(protocol) {
  return protocol === 'https:' || protocol === 'wss:' ? 443 : 80;
}

/**
 * Used to decide what the browser may load, at two levels.
 *
 * `allows` judges a request by its URL, before it is sent: a top-level
 * navigation may only open the sandbox app's origin, and no URL may name a
 * loopback, link-local or private address, or a local host name, other than
 * the app's. Chromium follows an HTTP redirect without asking again, so this
 * only sees the first URL of a redirect chain.
 *
 * `destination` judges each connection the browser opens, through the
 * sidecar's egress proxy, whatever URL or redirect led to it. The app's own
 * host and port are always reachable. Anything else must resolve only to
 * public addresses, and the proxy connects to the address checked here, so a
 * name whose answer changes between two lookups cannot move the connection
 * onto a private address.
 */
export class NetworkPolicy {
  /**
   * @param {object} options
   * @param {string} options.appOrigin the sandbox app's origin
   * @param {(hostname: string) => Promise<string[]>} [options.resolve] how host names are resolved
   * @param {(address: string) => boolean} [options.isPrivate] which IP addresses are refused
   * @param {number} [options.cacheMs] how long a resolution is reused
   */
  constructor({ appOrigin, resolve = resolveAll, isPrivate = isPrivateAddress, cacheMs = 60_000 }) {
    this.appOrigin = appOrigin;
    const app = new URL(appOrigin);
    this.appHost = bare(app.hostname);
    this.appPort = Number(app.port || defaultPort(app.protocol));
    this.resolve = resolve;
    this.isPrivate = isPrivate;
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
   * Whether a page on `url` is one of the sandbox app's. A page that is not
   * on the web (about:blank, an error page) is not elsewhere either.
   *
   * @param {string} url
   * @returns {boolean}
   */
  onApp(url) {
    let target;
    try {
      target = new URL(url);
    } catch {
      return true;
    }
    if (target.protocol !== 'http:' && target.protocol !== 'https:') return true;
    return target.origin === this.appOrigin;
  }

  /**
   * Whether the browser may send a request to `url`, judged by the URL alone.
   *
   * @param {string} url
   * @param {{ topLevelNavigation?: boolean }} [options]
   * @returns {boolean}
   */
  allows(url, { topLevelNavigation = false } = {}) {
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

    const hostname = bare(target.hostname);
    return !this.isPrivate(hostname) && !isLocalName(hostname);
  }

  // A WebSocket URL is the app's when it names the app's host and port.
  sameOriginAsApp(target) {
    if (target.origin === this.appOrigin) return true;
    if (target.protocol !== 'ws:' && target.protocol !== 'wss:') return false;

    const http = new URL(target.toString());
    http.protocol = target.protocol === 'ws:' ? 'http:' : 'https:';
    return http.origin === this.appOrigin;
  }

  /**
   * Returns the address a browser connection to `hostname`:`port` is to be
   * made to, or why it may not be made.
   *
   * @param {string} hostname a host name or IP address, IPv6 with or without brackets
   * @param {number} port
   * @returns {Promise<{ address: string, refusal: null } | { address: null, refusal: string }>}
   */
  async destination(hostname, port) {
    const host = bare(hostname);
    if (this.isApp(host, port)) return { address: host, refusal: null };

    const refused = (reason) => ({ address: null, refusal: `${host}:${port} ${reason}` });
    if (isLocalName(host)) return refused('is a local host name');
    if (isIP(host)) return this.isPrivate(host) ? refused('is a loopback, link-local or private address') : { address: host, refusal: null };

    const addresses = await this.lookup(host);
    if (addresses.length === 0) return refused('does not resolve');
    if (addresses.some((address) => this.isPrivate(address))) return refused('resolves to a loopback, link-local or private address');
    return { address: addresses[0], refusal: null };
  }

  isApp(hostname, port) {
    return bare(hostname) === this.appHost && port === this.appPort;
  }

  async lookup(hostname) {
    const cached = this.resolved.get(hostname);
    if (cached && cached.until > Date.now()) return cached.addresses;

    let addresses = [];
    try {
      addresses = await this.resolve(hostname);
    } catch {
      // A name that does not resolve is refused.
    }
    this.resolved.set(hostname, { addresses, until: Date.now() + this.cacheMs });
    return addresses;
  }
}
