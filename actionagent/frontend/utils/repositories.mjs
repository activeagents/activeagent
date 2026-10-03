// Pure helpers for choosing GitHub repositories by full name ("owner/name").

// Returns the repositories whose full name contains `filter`, ignoring case.
// A missing list is treated as empty.
export function filterRepositories(repositories, filter = '') {
  const needle = filter.toLowerCase();
  return (repositories || []).filter((repository) => repository.full_name.toLowerCase().includes(needle));
}

// Returns a new Set with `fullName` added, or removed when it was present.
export function toggleRepository(selection, fullName) {
  const next = new Set(selection);
  if (next.has(fullName)) next.delete(fullName); else next.add(fullName);
  return next;
}
