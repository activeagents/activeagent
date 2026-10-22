import React from 'react';
import { MONO } from './primitives';
import { RANK_WORDS } from '../../utils/comparison.mjs';

// Rank-tinted value pill for comparison cells (DESIGN_SPEC "Ranked Data &
// Comparison Tables"): full pill, mono 700, tabular numerals, tinted from the
// semantic soft/text pairs by rank within its column. The pill carries the
// formatted value and a visually hidden rank word, so colour is never the
// only signal. Not for status words (Badge) or the identity cell.
const RANK_STYLE = {
  good: { background: 'var(--color-success-soft)', color: 'var(--color-success-text)' },
  mid: { background: 'var(--color-warning-soft)', color: 'var(--color-warning-text)' },
  poor: { background: 'var(--color-error-soft)', color: 'var(--color-error-text)' },
  none: { background: 'var(--color-muted)', color: 'var(--color-text-cell)' },
};

const SR_ONLY = { position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0 0 0 0)', whiteSpace: 'nowrap' };

export const SIZES = {
  compact: { padding: '5px 11px', fontSize: 12, minWidth: '6ch' },
  product: { padding: '6px 12px', fontSize: 13, minWidth: '7ch' },
  marketing: { padding: '10px 16px', fontSize: 15, minWidth: '7ch' },
};

export default function ValuePill({ rank = 'none', size = 'product', children, title, style, testId }) {
  const tone = RANK_STYLE[rank] || RANK_STYLE.none;
  const dims = SIZES[size] || SIZES.product;
  return (
    <span
      className="aa-pill"
      data-rank={rank}
      data-testid={testId}
      title={title}
      style={{
        display: 'inline-block', borderRadius: 9999, textAlign: 'center', whiteSpace: 'nowrap',
        fontFamily: MONO, fontWeight: 700, lineHeight: 1.2, fontVariantNumeric: 'tabular-nums',
        ...dims, ...tone, ...style,
      }}
    >
      {children}
      {rank !== 'none' && <span style={SR_ONLY}>{` ${RANK_WORDS[rank]}`}</span>}
    </span>
  );
}
