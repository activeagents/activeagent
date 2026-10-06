// A Playwright storage state (cookies and per-origin localStorage) limited to
// the sandbox app, the only site its browser opens. The engine keeps one
// as a project secret, so a later browser of the same app starts signed in.

const SAME_SITE = new Set(['Strict', 'Lax', 'None']);

export class StorageStateError extends Error {}

function fail(message) {
  throw new StorageStateError(message);
}

// Whether a cookie for `domain` is sent to `hostname`: the same host, or a
// parent domain the cookie names with or without its leading dot.
function cookieDomainMatches(domain, hostname) {
  const bare = String(domain).replace(/^\./, '').toLowerCase();
  return bare !== '' && (hostname === bare || hostname.endsWith(`.${bare}`));
}

function cookie(value, index) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`cookie ${index + 1} must be an object`);
  for (const key of ['name', 'value', 'domain', 'path']) {
    if (typeof value[key] !== 'string') fail(`cookie ${index + 1} needs a string ${key}`);
  }

  const result = { name: value.name, value: value.value, domain: value.domain, path: value.path || '/' };
  result.expires = Number.isFinite(value.expires) ? value.expires : -1;
  result.httpOnly = value.httpOnly === true;
  result.secure = value.secure === true;
  result.sameSite = SAME_SITE.has(value.sameSite) ? value.sameSite : 'Lax';
  return result;
}

function origin(value, index) {
  if (!value || typeof value !== 'object' || typeof value.origin !== 'string') fail(`origin ${index + 1} needs an origin`);
  const localStorage = value.localStorage ?? [];
  if (!Array.isArray(localStorage) || localStorage.some((item) => typeof item?.name !== 'string' || typeof item?.value !== 'string')) {
    fail(`origin ${index + 1}'s localStorage must be a list of { name, value } strings`);
  }
  return { origin: value.origin, localStorage: localStorage.map(({ name, value: item }) => ({ name, value: item })) };
}

/**
 * Validates a storage state and returns the part of it that belongs to
 * `appOrigin`: the cookies its host is sent and the localStorage of that
 * origin. Anything else is dropped rather than refused, since a state saved
 * from a browser that followed a link elsewhere still signs the app in.
 *
 * @param {object} state { cookies: [...], origins: [...] }
 * @param {string} appOrigin e.g. "http://127.0.0.1:3000"
 * @returns {{ cookies: object[], origins: object[] }}
 * @throws {StorageStateError} naming the first malformed entry
 */
export function appStorageState(state, appOrigin) {
  if (!state || typeof state !== 'object' || Array.isArray(state)) fail('storage_state must be an object');
  const cookies = state.cookies ?? [];
  const origins = state.origins ?? [];
  if (!Array.isArray(cookies) || !Array.isArray(origins)) fail('storage_state needs cookies and origins lists');

  const { hostname } = new URL(appOrigin);
  return {
    cookies: cookies.map(cookie).filter((entry) => cookieDomainMatches(entry.domain, hostname.toLowerCase())),
    origins: origins.map(origin).filter((entry) => entry.origin === appOrigin),
  };
}

/**
 * The browser context's storage state limited to `appOrigin` (see
 * appStorageState).
 *
 * @param {import('playwright').BrowserContext} context
 * @param {string} appOrigin
 */
export async function exportStorageState(context, appOrigin) {
  return appStorageState(await context.storageState(), appOrigin);
}
