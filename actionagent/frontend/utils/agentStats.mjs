// How the agent surfaces (the Agents home, the agent page) write a run
// count, an error rate, a duration, a cost and a last-seen time, and the
// tone behind a score or an activity dot, so a figure reads the same in
// every row:
//
//   - a run count groups its thousands: "1,284"; nothing recorded is "0"
//   - a success rate in percent reads as its error rate, one decimal: "0.4%"
//   - a duration is "410ms" under a second and "1.8s" from there
//   - a cost has two decimals, "<$0.01" under a cent, and "—" when nothing
//     priceable ran (not "$0.00", which would read as free)
//   - a last-seen time is relative up to a month, then the locale date
//
// Values stay as the API records them; only their display changes here.
// Pure, and reads nothing from window, so the node tests can pin it.

const EMPTY = '—';

const finite = (value) => value != null && value !== '' && Number.isFinite(Number(value));

// 1284 → "1,284"; a missing count → "0".
export const fmtRuns = (n) => (finite(n) ? Math.round(Number(n)).toLocaleString('en-US') : '0');

// A success rate in percent → the error rate: 99.6 → "0.4%". "—" when no
// run was scored. Float noise is trimmed before rounding, so 100 − 99.95 is
// the decimal 0.05 and rounds up.
export const fmtErrorRate = (successRatePercent) => {
  if (!finite(successRatePercent)) return EMPTY;
  const errors = Number(Math.max(0, 100 - Number(successRatePercent)).toFixed(9));
  return `${errors.toFixed(1)}%`;
};

// Milliseconds → "410ms" under a second, "1.8s" from there. "—" when nothing ran.
export const fmtDuration = (ms) => {
  if (!finite(ms)) return EMPTY;
  const value = Number(ms);
  if (value < 1000) return `${Math.round(value)}ms`;
  return `${(value / 1000).toFixed(1)}s`;
};

// USD → "$12.40"; a positive amount under a cent → "<$0.01"; nil → "—".
export const fmtAgentCost = (usd) => {
  if (!finite(usd)) return EMPTY;
  const amount = Number(usd);
  if (amount > 0 && amount < 0.01) return '<$0.01';
  return `$${amount.toFixed(2)}`;
};

// An ISO time → "just now" (under a minute), "5m ago", "3h ago", "4d ago",
// then the locale date from 30 days; "never" when there is none. `now` is a
// timestamp, injectable so a test is fixed. A time ahead of `now` (clock
// skew) reads as "just now".
export const fmtLastSeen = (iso, now = Date.now()) => {
  if (!iso) return 'never';
  const at = new Date(iso).getTime();
  if (!Number.isFinite(at)) return 'never';
  const seconds = Math.max(0, Math.floor((Number(now) - at) / 1000));
  if (seconds < 60) return 'just now';
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(at).toLocaleDateString();
};

// A 0..1 evaluation score → its tone: ≥ 0.85 success, ≥ 0.7 warning, below
// that error; no score → muted.
export const evalTone = (score) => {
  if (!finite(score)) return 'muted';
  const value = Number(score);
  if (value >= 0.85) return 'success';
  if (value >= 0.7) return 'warning';
  return 'error';
};

// The dot before an agent's name, from its `{ runs, success_rate }` (rate in
// percent): muted with no runs in the window, warning once more than 2% of
// them failed (the design turns the dot amber from about 3% errors and keeps
// it green under 1%), success otherwise.
export const activityTone = ({ runs, success_rate } = {}) => {
  if (!finite(runs) || Number(runs) <= 0) return 'muted';
  if (finite(success_rate) && Number(success_rate) < 98) return 'warning';
  return 'success';
};
