// The one seam every dashboard request goes through. Components call plain
// fetch("/api/...") and this fills in what they would otherwise each have to
// remember:
//
// * the engine's mount path — the engine can be mounted anywhere
//   ("/activeagents", "/admin/agents", the root of a subdomain), so absolute
//   "/api/..." paths are rewritten onto it;
// * the Rails CSRF token on every mutating request. The API authenticates
//   with the host's session cookie, so it verifies the token like any other
//   form post; a per-component header was forgotten in most places.

const MUTATING_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

// Resolves a fetch call onto the API: returns the [input, init] to hand the
// real fetch, or null when the request is not a same-origin "/api/" call and
// should pass through untouched.
export function resolveApiRequest(input, init, { base = '', csrfToken, origin }) {
  let url;
  if (typeof input === 'string') {
    if (!input.startsWith('/api/')) return null;
    url = `${base}${input}`;
  } else if (typeof Request !== 'undefined' && input instanceof Request) {
    const parsed = new URL(input.url, origin);
    if (parsed.origin !== origin || !parsed.pathname.startsWith('/api/')) return null;
    url = `${origin}${base}${parsed.pathname}${parsed.search}`;
  } else {
    return null;
  }

  const request = typeof input === 'string' ? url : new Request(url, input);
  const method = (init?.method || (typeof input === 'string' ? 'GET' : input.method)).toUpperCase();
  if (!MUTATING_METHODS.has(method) || !csrfToken) return [request, init];

  const headers = new Headers(init?.headers ?? (typeof input === 'string' ? undefined : input.headers));
  if (!headers.has('X-CSRF-Token')) headers.set('X-CSRF-Token', csrfToken);
  return [request, { ...init, headers }];
}

// Reads the token csrf_meta_tags renders into the layout. Read per request
// rather than once, so a token Rails rotates (e.g. after sign-in) is picked up.
export function csrfTokenFromMeta(doc = globalThis.document) {
  return doc?.querySelector('meta[name="csrf-token"]')?.content || null;
}

export function installApiFetch(mountPath, target = globalThis) {
  const base = mountPath.replace(/\/$/, '');
  const original = target.fetch.bind(target);

  target.fetch = (input, init) => {
    const resolved = resolveApiRequest(input, init, {
      base,
      csrfToken: csrfTokenFromMeta(),
      origin: target.location.origin,
    });
    return resolved ? original(...resolved) : original(input, init);
  };
}
