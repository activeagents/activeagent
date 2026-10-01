// How every evaluation surface writes a pass count, a score and a cost, so
// the run list, the matrix, the scorecards and the page tiles read alike:
//
//   - a pass/fail fraction carries its percentage: "14/16 · 88%"
//   - a 0..1 score (mean score, criterion score, task completion, judge
//     confidence, pass threshold) reads as a whole percent: "93%"
//   - money has four decimals, six below $0.001, "$0.00" for an explicit
//     zero, and a leading "~" when any part of it was estimated from tokens
//     × model rates rather than reported
//
// Values stay 0..1 and USD in transport; only their display changes here.
// Pure, and imports nothing, so the node tests can pin it.

const EMPTY = '—';

// Shown once per surface where a "~" figure is visible.
export const COST_LEGEND = '~ estimated from tokens × model rates';

const finite = (value) => value != null && value !== '' && Number.isFinite(Number(value));

// Half away from zero, on the decimal value: 14.5 → 15 even when the float
// arrived as 14.499999999999998.
const roundHalfUp = (value) => Math.sign(value) * Math.round(Number(Math.abs(value).toFixed(9)));

// 0.875 → "88%". "—" for a missing value.
export const fmtPercent = (fraction) => (finite(fraction) ? `${roundHalfUp(Number(fraction) * 100)}%` : EMPTY);

// 14 of 16 → "14/16 · 88%". "—" when nothing was scored (0/0).
export const fmtPasses = (passed, total) => {
  const count = Number(total) || 0;
  if (count <= 0) return EMPTY;
  const done = Number(passed) || 0;
  return `${done}/${count} · ${roundHalfUp((done * 100) / count)}%`;
};

// A 0..1 score as a percent: 0.93 → "93%".
export const fmtScore = (value) => fmtPercent(value);

// 0.7 → "pass ≥ 70%".
export const fmtThreshold = (value) => `pass ≥ ${fmtPercent(value)}`;

// 0.0243 → "$0.0243", 0.000697 → "$0.000697", 0 → "$0.00"; with
// `estimated`, "~$0.0243". "—" for a missing value.
export const fmtSpend = (value, { estimated = false } = {}) => {
  if (!finite(value)) return EMPTY;
  const amount = Number(value);
  const digits = amount === 0 ? 2 : Math.abs(amount) < 0.001 ? 6 : 4;
  return `${estimated ? '~' : ''}$${amount.toFixed(digits)}`;
};

const fmtCount = (value) => Math.round(Number(value) || 0).toLocaleString('en-US');

// A $/M rate with at least two decimals and no float noise: 5 → "$5.00/M",
// 0.075 → "$0.075/M".
const fmtPerMillion = (rate) => {
  const [whole, fraction = ''] = String(Number(Number(rate).toFixed(4))).split('.');
  return `$${whole}.${fraction.padEnd(2, '0')}/M`;
};

const FALLBACK_SOURCES = ['pattern', 'default'];

// The tooltip of an estimated figure: how it was worked out, e.g.
// "estimated: 2,328 in × $5.00/M + 423 out × $30.00/M · catalog rate".
// `rate` is the API's `{ input, output, source }` ($ per million tokens); a
// rate from the name-pattern table or the default appends "(fallback
// rate)". Without a rate it names the method only.
export const costTitle = ({ inputTokens, outputTokens, rate } = {}) => {
  if (!rate || !finite(rate.input) || !finite(rate.output)) return 'estimated from tokens × model rates';
  const source = rate.source || 'catalog';
  return `estimated: ${fmtCount(inputTokens)} in × ${fmtPerMillion(rate.input)} + ${fmtCount(outputTokens)} out × ${fmtPerMillion(rate.output)}`
    + ` · ${source} rate${FALLBACK_SOURCES.includes(source) ? ' (fallback rate)' : ''}`;
};
