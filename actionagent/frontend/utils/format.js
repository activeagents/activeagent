// Number, money, time and model-name formatting shared by the Metrics and
// Evaluations views and their panels. One implementation so `12.0K`, `2.86s`
// and `$0.0033` read the same everywhere on the dashboard.

// 12800 → "12.8K", 2400000 → "2.4M", 950 → "950".
export const fmtK = (value) => {
  const n = Number(value) || 0;
  if (Math.abs(n) >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (Math.abs(n) >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
  return `${Math.round(n)}`;
};

// Token counts read like fmtK; null/undefined read as an em dash.
export const fmtTokens = (value) => (value == null ? '—' : fmtK(value));

// 620 → "620ms", 1900 → "1.9s", null → "—".
export const fmtMs = (ms) => {
  if (ms == null || Number.isNaN(Number(ms))) return '—';
  const n = Number(ms);
  return n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 1 : 2).replace(/\.?0+$/, '')}s` : `${Math.round(n)}ms`;
};

// Money for totals: "$42.18". Sub-cent figures are not rounded to "$0.00",
// which reads as no spend.
export const fmtUSD = (value) => {
  if (value == null) return '—';
  const n = Number(value);
  if (n === 0) return '$0.00';
  if (Math.abs(n) < 0.01) return `$${n.toFixed(4)}`;
  return `$${n.toFixed(2)}`;
};

// Money for a single replay or per-request figure: "$0.0033".
export const fmtCost = (value, digits = 4) => (value == null ? '—' : `$${Number(value).toFixed(digits)}`);

// 0.343 → "34%".
export const fmtPct = (ratio, digits = 0) => `${(Number(ratio || 0) * 100).toFixed(digits)}%`;

// Scores render with two decimals everywhere: 1 → "1.00", 0.5 → "0.50".
export const fmtScore = (score) => (score == null ? '—' : Number(score).toFixed(2));

// A previous-period change: 23.4 → "+23%", -12 → "-12%", null → "—".
// `unit` is "%" for ratios and " pt" for percentage-point deltas.
export const fmtDelta = (value, unit = '%', digits = 0) => {
  if (value == null || Number.isNaN(Number(value))) return '—';
  const n = Number(value);
  const sign = n > 0 ? '+' : n < 0 ? '-' : '';
  return `${sign}${Math.abs(n).toFixed(digits)}${unit}`;
};

// "just now", "5 min ago", "2 hours ago", "3 days ago".
export const timeAgo = (iso) => {
  if (!iso) return '';
  const mins = Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins} min ago`;
  if (mins < 1440) {
    const hours = Math.floor(mins / 60);
    return `${hours} hour${hours === 1 ? '' : 's'} ago`;
  }
  const days = Math.floor(mins / 1440);
  return `${days} day${days === 1 ? '' : 's'} ago`;
};

// "openrouter/openai/gpt-4o-mini" → { short: "gpt-4o-mini", provider: "openrouter/openai" }.
// A bare name has no provider. The label is what the user typed and keys
// a model's cohort in a run, so it is never rewritten — only split for display.
export const splitModelLabel = (label, provider = null) => {
  const text = String(label || '');
  const slash = text.lastIndexOf('/');
  if (slash > 0) return { short: text.slice(slash + 1), provider: text.slice(0, slash) };
  return { short: text, provider: provider || '' };
};

export const shortModel = (label) => splitModelLabel(label).short;
