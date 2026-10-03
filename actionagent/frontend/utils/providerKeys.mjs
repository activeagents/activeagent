// Labels and paths for provider keys in their two scopes: the organization's
// shared keys, and a member's personal keys (GET /api/provider_keys?scope=).

const EFFECTIVE_SOURCE_LABELS = {
  personal: 'Your key',
  // A host resolver answers per organization, so its key is the
  // organization's as far as a member can tell.
  host_resolver: 'Organization key',
  organization: 'Organization key',
  config: 'Platform default',
  none: 'Not configured',
};

// The badge for where the caller's own runs get a provider's credentials,
// from a row's effective_source; null for a source the API does not report
// (a connection credential).
export function effectiveSourceLabel(source) {
  return EFFECTIVE_SOURCE_LABELS[source] || null;
}

// The provider keys endpoint for `scope`. No scope is the organization's,
// which is the endpoint's default, so the path stays as it was.
export function providerKeysPath(path, scope) {
  return scope ? `${path}?scope=${encodeURIComponent(scope)}` : path;
}

// "Set by Grace · updated 10/2/2026" for a stored key, from its set_by and
// updated_at; just the part that is known, or null when neither is.
export function keyAuditLine({ set_by: setBy, updated_at: updatedAt } = {}, formatDate = (value) => new Date(value).toLocaleDateString()) {
  const parts = [];
  if (setBy?.name) parts.push(`Set by ${setBy.name}`);
  if (updatedAt) parts.push(`${parts.length ? 'updated' : 'Updated'} ${formatDate(updatedAt)}`);
  return parts.length ? parts.join(' · ') : null;
}
