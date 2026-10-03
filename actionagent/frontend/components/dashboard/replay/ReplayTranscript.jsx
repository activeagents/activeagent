import React, { memo, useEffect, useRef } from 'react';
import { MONO } from '../primitives';
import { LANE_ROWS } from './ReplayScrubber';
import { formatClock } from '../../../utils/replayTimeline.mjs';
import { entryFailed, entrySummary } from '../../../utils/replayEntries.mjs';

// The session's entries in time order, the one playing highlighted and
// kept in view. Choosing an entry seeks to its start and shows it in full.

const LANE_STYLE = Object.fromEntries(LANE_ROWS.map((row) => [row.lane, row]));

const Row = memo(function Row({ entry, startMs, current, selected, onChoose, rowRef }) {
  const lane = LANE_STYLE[entry.lane];
  const failed = entryFailed(entry);
  return (
    <button
      type="button"
      ref={rowRef}
      data-testid="replay-entry"
      aria-current={current ? 'step' : undefined}
      onClick={() => onChoose(entry)}
      style={{
        display: 'flex', alignItems: 'baseline', gap: 10, width: '100%', textAlign: 'left', cursor: 'pointer',
        padding: '6px 12px', border: 'none', borderLeft: `3px solid ${current ? lane.color : 'transparent'}`,
        background: selected ? 'var(--color-accent-ui-tint)' : current ? 'var(--color-hover)' : 'transparent',
        fontFamily: 'inherit',
      }}
    >
      <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)', width: 56, flexShrink: 0 }}>
        {formatClock(entry.startMs - startMs)}
      </span>
      <span style={{ fontFamily: MONO, fontSize: 10, textTransform: 'uppercase', color: lane.color, width: 64, flexShrink: 0 }}>
        {lane.label}
      </span>
      <span style={{ fontSize: 13, color: failed ? 'var(--color-error-text)' : 'var(--color-text-cell)', minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
        {entrySummary(entry)}
      </span>
      {entry.duration_ms > 0 && (
        <span style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)', flexShrink: 0 }}>
          {Math.round(entry.duration_ms)}ms
        </span>
      )}
    </button>
  );
});

export default memo(function ReplayTranscript({ entries, startMs, currentId, selectedId, playing, onChoose }) {
  const list = useRef(null);
  const currentRow = useRef(null);

  // Scrolls the list itself rather than calling scrollIntoView, which would
  // scroll the dashboard page too.
  useEffect(() => {
    const row = currentRow.current;
    const container = list.current;
    if (!playing || !row || !container) return;
    const top = row.offsetTop;
    if (top < container.scrollTop || top + row.offsetHeight > container.scrollTop + container.clientHeight) {
      container.scrollTop = Math.max(0, top - container.clientHeight / 3);
    }
  }, [currentId, playing]);

  if (!entries.length) {
    return <div style={{ padding: 20, fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>no entries in the lanes shown</div>;
  }

  return (
    <div ref={list} data-testid="replay-transcript" style={{ maxHeight: 460, overflowY: 'auto', position: 'relative' }}>
      {entries.map((entry) => (
        <Row
          key={entry.id}
          entry={entry}
          startMs={startMs}
          current={entry.id === currentId}
          selected={entry.id === selectedId}
          onChoose={onChoose}
          rowRef={entry.id === currentId ? currentRow : undefined}
        />
      ))}
    </div>
  );
});
