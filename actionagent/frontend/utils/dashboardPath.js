import { mountedPath, mountRelativePath } from './mountPath.mjs';

// Client-side routes, resolved against wherever the engine is mounted.
//
// The dashboard can live at "/activeagents", "/dashboard", the root of a
// subdomain, or anywhere else the host app chooses, so no path in the UI may
// be written as an absolute literal. The mount is published by the entry
// point from the props the server rendered.
export function dashboardPath(path = '') {
  return mountedPath(window.ACTIVE_AGENT_DASHBOARD?.mountPath, path);
}

// Pushes a client-side route under the mount, with `state` as its history
// entry's state.
export function pushDashboardPath(path = '', state = {}) {
  window.history.pushState(state, '', dashboardPath(path));
}

// The inverse of dashboardPath: the current location with the mount
// stripped, '/' at the mount root. Routing has to match against this rather
// than the raw pathname — a mount whose prefix contains a view keyword (the
// README's own /admin/agents, or /demo) otherwise trips the keyword checks
// and every deep link lands on the wrong view.
export function dashboardRelativePath(pathname = window.location.pathname) {
  return mountRelativePath(window.ACTIVE_AGENT_DASHBOARD?.mountPath, pathname);
}

// In-app navigation to a dashboard route. Accepts a mount-relative path
// ("/tools") or one that already carries the mount. `state` becomes the new
// history entry's state.
export function navigateTo(path, state = {}) {
  if (!path) return;
  const relative = dashboardRelativePath(path);
  pushDashboardPath(relative, state);
  window.dispatchEvent(new CustomEvent('dashboard:navigate', { detail: { path: dashboardPath(relative) } }));
}
