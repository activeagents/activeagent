import React, { memo, useRef } from 'react';
import { MONO } from '../primitives';
import { axisGaps, formatSpan, timeToAxis } from '../../../utils/replayTimeline.mjs';
import { entryFailed } from '../../../utils/replayEntries.mjs';

// The session's lanes on its playback axis, with the playhead. Clicking or
// dragging on the lanes seeks; the arrow keys move a hundredth of the axis.

export const LANE_ROWS = [
  { lane: 'message', label: 'messages', color: 'var(--color-info)' },
  { lane: 'llm', label: 'model', color: 'var(--color-token-out)' },
  { lane: 'tool', label: 'tools', color: 'var(--color-warning)' },
  { lane: 'browser', label: 'browser', color: 'var(--color-success)' },
];

const ROW_HEIGHT = 18;
const LABEL_WIDTH = 76;

const percent = (axis, axisMs) => (axis.totalMs ? (axisMs / axis.totalMs) * 100 : 0);

// The marks of every lane. Memoized apart from the playhead, which moves on
// every frame while the marks do not.
const LaneMarks = memo(function LaneMarks({ axis, entries, recordings }) {
  const gaps = axisGaps(axis);
  return (
    <>
      {gaps.map((gap) => (
        <div
          key={`gap-${gap.axisStart}`}
          title={`${formatSpan(gap.skippedMs)} idle, shortened`}
          style={{
            position: 'absolute', top: 0, bottom: 0, left: `${percent(axis, gap.axisStart)}%`,
            width: `${percent(axis, gap.axisEnd - gap.axisStart)}%`,
            background: 'repeating-linear-gradient(135deg, var(--color-muted) 0 4px, transparent 4px 8px)',
          }}
        />
      ))}
      {LANE_ROWS.map((row, rowIndex) => (
        <React.Fragment key={row.lane}>
          {row.lane === 'browser' && recordings.map((recording) => {
            const start = timeToAxis(axis, recording.startMs);
            return (
              <div
                key={`recording-${recording.id}`}
                title={`browser recording ${recording.id}`}
                style={{
                  position: 'absolute', top: rowIndex * ROW_HEIGHT + 7, height: 4, borderRadius: 2,
                  left: `${percent(axis, start)}%`, width: `${Math.max(percent(axis, timeToAxis(axis, recording.endMs) - start), 0.3)}%`,
                  background: row.color, opacity: 0.35,
                }}
              />
            );
          })}
          {entries.filter((entry) => entry.lane === row.lane).map((entry) => {
            const start = timeToAxis(axis, entry.startMs);
            return (
              <div
                key={entry.id}
                style={{
                  position: 'absolute', top: rowIndex * ROW_HEIGHT + 4, height: ROW_HEIGHT - 8, borderRadius: 2,
                  left: `${percent(axis, start)}%`, width: `max(3px, ${percent(axis, timeToAxis(axis, entry.endMs) - start)}%)`,
                  background: entryFailed(entry) ? 'var(--color-error)' : row.color,
                }}
              />
            );
          })}
        </React.Fragment>
      ))}
    </>
  );
});

export default function ReplayScrubber({ axis, entries, recordings, position, onSeek }) {
  const track = useRef(null);
  const height = LANE_ROWS.length * ROW_HEIGHT;

  const seekFromPointer = (event) => {
    const rect = track.current?.getBoundingClientRect();
    if (!rect?.width) return;
    const fraction = Math.min(Math.max((event.clientX - rect.left) / rect.width, 0), 1);
    onSeek(fraction * axis.totalMs);
  };

  const onKeyDown = (event) => {
    const step = axis.totalMs / 100;
    if (event.key === 'ArrowRight') onSeek(position + step);
    else if (event.key === 'ArrowLeft') onSeek(position - step);
    else if (event.key === 'Home') onSeek(0);
    else if (event.key === 'End') onSeek(axis.totalMs);
    else return;
    event.preventDefault();
  };

  return (
    <div data-testid="replay-scrubber" style={{ display: 'flex', gap: 8 }}>
      <div style={{ width: LABEL_WIDTH, flexShrink: 0 }}>
        {LANE_ROWS.map((row) => (
          <div key={row.lane} style={{ height: ROW_HEIGHT, display: 'flex', alignItems: 'center', gap: 6, fontFamily: MONO, fontSize: 10, color: 'var(--color-text-muted)', textTransform: 'uppercase' }}>
            <span style={{ width: 8, height: 8, borderRadius: 2, background: row.color }} />
            {row.label}
          </div>
        ))}
      </div>
      <div
        ref={track}
        role="slider"
        tabIndex={0}
        aria-label="Session position"
        aria-valuemin={0}
        aria-valuemax={Math.round(axis.totalMs)}
        aria-valuenow={Math.round(position)}
        onPointerDown={(event) => {
          event.currentTarget.setPointerCapture?.(event.pointerId);
          seekFromPointer(event);
        }}
        onPointerMove={(event) => {
          if (event.buttons === 1) seekFromPointer(event);
        }}
        onKeyDown={onKeyDown}
        style={{
          position: 'relative', flex: 1, height, cursor: 'pointer', borderRadius: 6, overflow: 'hidden',
          background: 'var(--color-background)', border: '1px solid var(--color-border-light)', touchAction: 'none',
        }}
      >
        <LaneMarks axis={axis} entries={entries} recordings={recordings} />
        <div
          style={{
            position: 'absolute', top: 0, bottom: 0, width: 2, marginLeft: -1, pointerEvents: 'none',
            left: `${percent(axis, position)}%`, background: 'var(--color-text-primary)',
          }}
        />
      </div>
    </div>
  );
}
