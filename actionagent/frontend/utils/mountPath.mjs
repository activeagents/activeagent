// Joins and strips the engine's mount path. utils/dashboardPath.js applies
// these to the mount the server rendered; they take it as an argument so they
// run outside a browser.

// Returns `path` under the mount, or '/' for the root of an empty mount:
// `mountedPath('/dashboard/', '/traces')` → `'/dashboard/traces'`.
export function mountedPath(mountPath, path = '') {
  const base = (mountPath || '').replace(/\/$/, '');
  return `${base}${path}` || '/';
}

// Returns `pathname` with the mount stripped, '/' at the mount root:
// `mountRelativePath('/dashboard', '/dashboard/traces')` → `'/traces'`. A
// pathname outside the mount is returned unchanged.
export function mountRelativePath(mountPath, pathname) {
  const base = (mountPath || '').replace(/\/$/, '');
  if (base && (pathname === base || pathname.startsWith(`${base}/`))) {
    return pathname.slice(base.length) || '/';
  }
  return pathname;
}
