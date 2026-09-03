// Client-side routes, resolved against wherever the engine is mounted.
//
// The dashboard can live at "/activeagents", "/dashboard", the root of a
// subdomain, or anywhere else the host app chooses, so no path in the UI may
// be written as an absolute literal. The mount is published by the entry
// point from the props the server rendered.
export function dashboardPath(path = '') {
  const base = (window.ACTIVE_AGENT_DASHBOARD?.mountPath || '').replace(/\/$/, '');
  return `${base}${path}` || '/';
}

// Pushes a client-side route under the mount.
export function pushDashboardPath(path = '') {
  window.history.pushState({}, '', dashboardPath(path));
}

// The inverse of dashboardPath: the current location with the mount
// stripped, '/' at the mount root. Routing has to match against this rather
// than the raw pathname — a mount whose prefix contains a view keyword (the
// README's own /admin/agents, or /demo) otherwise trips the keyword checks
// and every deep link lands on the wrong view.
export function dashboardRelativePath(pathname = window.location.pathname) {
  const base = (window.ACTIVE_AGENT_DASHBOARD?.mountPath || '').replace(/\/$/, '');
  if (base && (pathname === base || pathname.startsWith(`${base}/`))) {
    return pathname.slice(base.length) || '/';
  }
  return pathname;
}
