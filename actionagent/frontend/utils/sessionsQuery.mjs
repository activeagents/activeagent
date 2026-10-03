// The Sessions index's filters: how they are offered, kept in the page's
// URL, and sent to GET /api/sessions (see SessionIndex for what each one
// matches on the server).
//
// Filters are kept as the strings the form controls hold:
//   agentId  an agent id, '' for every agent
//   user     'me', or '' for anyone
//   source   'dashboard', 'evaluation' or 'agent', or ''
//   outcome  'failed' or 'passed', or ''
//   from, to dates as YYYY-MM-DD, both inclusive, or ''

export const SESSION_SOURCES = [
  { value: '', label: 'Every source' },
  { value: 'dashboard', label: 'Dashboard conversations' },
  { value: 'evaluation', label: 'Evaluation replays' },
  { value: 'agent', label: 'Agent browsers' },
];

export const SESSION_OUTCOMES = [
  { value: '', label: 'Any outcome' },
  { value: 'failed', label: 'Failed or errored' },
  { value: 'passed', label: 'Passed' },
];

export const EMPTY_FILTERS = Object.freeze({ agentId: '', user: '', source: '', outcome: '', from: '', to: '' });

const SEARCH_KEYS = { agentId: 'agent_id', user: 'user', source: 'source', outcome: 'outcome', from: 'from', to: 'to' };
const DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

const VALID = {
  agentId: (value) => /^\d+$/.test(value),
  user: (value) => value === 'me',
  source: (value) => SESSION_SOURCES.some((option) => option.value && option.value === value),
  outcome: (value) => SESSION_OUTCOMES.some((option) => option.value && option.value === value),
  from: (value) => DATE.test(value),
  to: (value) => DATE.test(value),
};

// `filters` with every unknown or malformed value cleared.
export function cleanFilters(filters = {}) {
  const clean = { ...EMPTY_FILTERS };
  for (const key of Object.keys(EMPTY_FILTERS)) {
    const value = String(filters[key] ?? '');
    if (value && VALID[key](value)) clean[key] = value;
  }
  return clean;
}

export function hasFilters(filters = {}) {
  return Object.values(cleanFilters(filters)).some(Boolean);
}

// The filters a page URL's query string names.
export function filtersFromSearch(search = '') {
  const params = new URLSearchParams(search);
  const filters = {};
  for (const [key, name] of Object.entries(SEARCH_KEYS)) filters[key] = params.get(name) || '';
  return cleanFilters(filters);
}

// The query string ('' or '?…') that keeps `filters` in the page URL.
export function filtersSearch(filters = {}) {
  const params = new URLSearchParams();
  const clean = cleanFilters(filters);
  for (const [key, name] of Object.entries(SEARCH_KEYS)) {
    if (clean[key]) params.set(name, clean[key]);
  }
  const query = params.toString();
  return query ? `?${query}` : '';
}

// The first moment of a YYYY-MM-DD date in the browser's time zone, plus
// `days`, as ISO 8601.
function localDay(value, days = 0) {
  const [, year, month, day] = value.match(DATE);
  return new Date(Number(year), Number(month) - 1, Number(day) + days).toISOString();
}

// The URL of a page of GET /api/sessions. Dates are the browser's local
// days, so `to` asks for everything before the next day began. `before` is
// the previous page's next_before.
export function sessionsPath(filters = {}, { before = null, perPage = 25 } = {}) {
  const clean = cleanFilters(filters);
  const params = new URLSearchParams();
  if (clean.agentId) params.set('agent_id', clean.agentId);
  if (clean.user) params.set('user', clean.user);
  if (clean.source) params.set('source', clean.source);
  if (clean.outcome) params.set('outcome', clean.outcome);
  if (clean.from) params.set('from', localDay(clean.from));
  if (clean.to) params.set('to', localDay(clean.to, 1));
  params.set('per_page', String(perPage));
  if (before) params.set('before', before);
  return `/api/sessions?${params}`;
}
