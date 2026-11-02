// Ranking for comparison tables (DESIGN_SPEC "Ranked Data & Comparison
// Tables"): every numeric column bands its rows into good / mid / poor, and
// sorts by the column's better direction first. Pure, so the dashboard's
// ComparisonTable and the evaluation report can share one definition.
//
// A column: { key, better: 'higher' | 'lower', band: 'tercile' | 'threshold'
// | 'none', thresholds: [good, mid], value(row) }. `value` defaults to
// row[key]; a null, undefined or non-finite value is unranked ('none') and
// sorts last whichever way the column is sorted.

export const RANK_WORDS = { good: 'best third', mid: 'middle third', poor: 'bottom third', none: 'not ranked' };

const finite = (value) => value != null && Number.isFinite(Number(value));

export const valueOf = (row, column) => (column.value ? column.value(row) : row?.[column.key]);

export const betterDirection = (column) => (column?.better === 'lower' ? 'ascending' : 'descending');

// Index -> 'good' | 'mid' | 'poor' | 'none' for every row of `rows`.
export const bandRows = (rows = [], column = {}) => {
  const bands = rows.map(() => 'none');
  const band = column.band || 'tercile';
  if (band === 'none') return bands;

  const ranked = rows.map((row, index) => ({ index, value: valueOf(row, column) })).filter((entry) => finite(entry.value)).map((entry) => ({ ...entry, value: Number(entry.value) }));
  if (band === 'threshold') {
    const [good, mid] = column.thresholds || [];
    const higher = column.better !== 'lower';
    ranked.forEach(({ index, value }) => {
      const beats = (cut) => (higher ? value >= cut : value <= cut);
      bands[index] = good != null && beats(good) ? 'good' : mid != null && beats(mid) ? 'mid' : 'poor';
    });
    return bands;
  }

  // Terciles. One row is good on its own; two rows split good / poor, so a
  // pair never reads as "both middling". Ties share the better band.
  ranked.sort((a, b) => (column.better === 'lower' ? a.value - b.value : b.value - a.value));
  if (ranked.length === 1) { bands[ranked[0].index] = 'good'; return bands; }
  const third = Math.ceil(ranked.length / 3);
  const cut = (position) => (ranked.length === 2 ? (position === 0 ? 'good' : 'poor') : position < third ? 'good' : position < third * 2 ? 'mid' : 'poor');
  let position = 0;
  ranked.forEach((entry, i) => {
    if (i > 0 && entry.value !== ranked[i - 1].value) position = i;
    bands[entry.index] = cut(position);
  });
  return bands;
};

// `rows` ordered by `column`, missing values last, stable within ties.
export const sortRows = (rows = [], column = {}, direction = 'descending') => {
  const text = column.kind === 'text';
  return rows
    .map((row, index) => ({ row, index, value: valueOf(row, column) }))
    .sort((a, b) => {
      const aMissing = text ? a.value == null || a.value === '' : !finite(a.value);
      const bMissing = text ? b.value == null || b.value === '' : !finite(b.value);
      if (aMissing || bMissing) return aMissing === bMissing ? a.index - b.index : aMissing ? 1 : -1;
      const order = text ? String(a.value).localeCompare(String(b.value)) : Number(a.value) - Number(b.value);
      return (direction === 'ascending' ? order : -order) || a.index - b.index;
    })
    .map((entry) => entry.row);
};

// The direction a first click on `column` sorts by: text ascending, numbers
// by their better direction, so the strongest row lands on top.
export const firstSortDirection = (column) => (column?.kind === 'text' ? 'ascending' : betterDirection(column));
