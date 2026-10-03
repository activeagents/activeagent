// The arithmetic behind the session replay view: a session timeline's lanes
// (GET .../timeline, see SessionTimeline) merged into one stream, the
// playback axis that shortens the idle stretches between them, and where a
// browser recording stands at a moment of the session.
//
// Session times are epoch milliseconds. Axis times are milliseconds along
// the playback axis, from 0 to its totalMs: the session's busy stretches
// keep their length, and each idle stretch between them is shortened to
// `gapMs`.

export const LANES = ['message', 'llm', 'tool', 'browser'];

function parseMs(value) {
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

// Every entry of `lanes` in one list, in time order, each with `lane`,
// `startMs` and `endMs`. Entries starting together keep LANES order, then
// their order within their lane. Entries without a readable start are
// dropped.
export function mergeLanes(lanes = {}) {
  const merged = [];
  LANES.forEach((lane, laneIndex) => {
    (lanes[lane] || []).forEach((entry, index) => {
      const startMs = parseMs(entry?.start);
      if (startMs === null) return;

      const duration = Math.max(0, Number(entry.duration_ms) || 0);
      merged.push({ entry: { ...entry, lane, startMs, endMs: startMs + duration }, laneIndex, index });
    });
  });
  merged.sort((a, b) => a.entry.startMs - b.entry.startMs || a.laneIndex - b.laneIndex || a.index - b.index);
  return merged.map(({ entry }) => entry);
}

// The recordings of a timeline (its `recordings`) that hold rrweb events,
// each with `startMs` and `endMs`, in start order.
export function browserRecordings(recordings = []) {
  return recordings
    .filter((recording) => recording?.rrweb?.event_count > 0 && parseMs(recording.rrweb.first_at) !== null)
    .map((recording) => {
      const startMs = parseMs(recording.rrweb.first_at);
      return { ...recording, startMs, endMs: Math.max(startMs, parseMs(recording.rrweb.last_at) ?? startMs) };
    })
    .sort((a, b) => a.startMs - b.startMs);
}

// The [start, end] ranges a session is busy in: each entry, and each
// browser recording as a whole.
export function sessionSpans(entries = [], recordings = []) {
  return [
    ...entries.map((entry) => [entry.startMs, entry.endMs]),
    ...recordings.map((recording) => [recording.startMs, recording.endMs]),
  ];
}

// The playback axis over `spans`. Spans closer than `maxGapMs` join one
// segment; each segment lasts at least `minSegmentMs`, so a lone instant
// can still be played through; the idle stretch between segments takes
// `gapMs` of the axis.
//
// Returns { segments: [{ startMs, endMs, axisStart, axisEnd }], totalMs,
// startMs, endMs }. An axis over no spans has no segments, totalMs 0 and
// null times.
export function playbackAxis(spans = [], { maxGapMs = 10_000, gapMs = 1_000, minSegmentMs = 1_000 } = {}) {
  const sorted = spans
    .filter(([start, end]) => Number.isFinite(start) && Number.isFinite(end))
    .map(([start, end]) => [start, Math.max(start, end)])
    .sort((a, b) => a[0] - b[0]);

  const joined = [];
  for (const [start, end] of sorted) {
    const last = joined[joined.length - 1];
    if (last && start - last[1] <= maxGapMs) last[1] = Math.max(last[1], end);
    else joined.push([start, end]);
  }

  let axisStart = 0;
  const segments = joined.map(([startMs, end]) => {
    const endMs = Math.max(end, startMs + minSegmentMs);
    const segment = { startMs, endMs, axisStart, axisEnd: axisStart + (endMs - startMs) };
    axisStart = segment.axisEnd + gapMs;
    return segment;
  });

  const last = segments[segments.length - 1];
  return {
    segments,
    gapMs,
    totalMs: last ? last.axisEnd : 0,
    startMs: segments[0]?.startMs ?? null,
    endMs: last?.endMs ?? null,
  };
}

// The idle stretches the axis shortened, as { axisStart, axisEnd, skippedMs }.
export function axisGaps(axis) {
  return axis.segments.slice(1).map((segment, index) => {
    const before = axis.segments[index];
    return { axisStart: before.axisEnd, axisEnd: segment.axisStart, skippedMs: segment.startMs - before.endMs };
  });
}

// The session time at `axisMs`. Inside an idle stretch, time runs across
// the whole stretch in proportion. Clamped to the axis.
export function axisToTime(axis, axisMs) {
  const { segments } = axis;
  if (!segments.length) return null;

  const at = Math.min(Math.max(axisMs, 0), axis.totalMs);
  for (let index = 0; index < segments.length; index += 1) {
    const segment = segments[index];
    if (at <= segment.axisEnd) return segment.startMs + (at - segment.axisStart);

    const next = segments[index + 1];
    if (next && at < next.axisStart) {
      return segment.endMs + ((at - segment.axisEnd) / (next.axisStart - segment.axisEnd)) * (next.startMs - segment.endMs);
    }
  }
  return axis.endMs;
}

// The axis position of session time `ms`; the inverse of axisToTime.
// Clamped to the axis.
export function timeToAxis(axis, ms) {
  const { segments } = axis;
  if (!segments.length || !Number.isFinite(ms)) return 0;

  for (let index = 0; index < segments.length; index += 1) {
    const segment = segments[index];
    if (ms <= segment.endMs) return Math.max(0, segment.axisStart + (ms - segment.startMs));

    const next = segments[index + 1];
    if (next && ms < next.startMs) {
      return segment.axisEnd + ((ms - segment.endMs) / (next.startMs - segment.endMs)) * (next.axisStart - segment.axisEnd);
    }
  }
  return axis.totalMs;
}

// Which stretch of the axis `axisMs` is in: 2i inside segment i, 2i + 1 in
// the idle stretch after it. Playback crosses an idle stretch faster than
// real time, so a change of stretch is when a browser replay must be moved.
export function axisStretchAt(axis, axisMs) {
  const index = axis.segments.findIndex((segment) => axisMs <= segment.axisEnd);
  if (index === -1) return Math.max(0, axis.segments.length * 2 - 2);
  return axisMs >= axis.segments[index].axisStart ? index * 2 : Math.max(0, index * 2 - 1);
}

// The index of the last entry that started at or before `ms`, or -1.
// `entries` are in start order.
export function entryIndexAt(entries, ms) {
  let low = 0;
  let high = entries.length - 1;
  let found = -1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    if (entries[middle].startMs <= ms) {
      found = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return found;
}

// The session time a step from `ms` moves to: forward, the start of the
// first entry after it; back, the start of the last entry before it. Null
// when there is none.
export function stepTime(entries, ms, direction) {
  if (direction > 0) return entries.find((entry) => entry.startMs > ms)?.startMs ?? null;

  for (let index = entries.length - 1; index >= 0; index -= 1) {
    if (entries[index].startMs < ms) return entries[index].startMs;
  }
  return null;
}

// The recording to show at `ms`: the one whose range holds it, else the
// last one that started before it, else the first.
export function recordingAt(recordings, ms) {
  if (!recordings.length) return null;

  const holding = recordings.find((recording) => ms >= recording.startMs && ms <= recording.endMs);
  if (holding) return holding;

  const started = recordings.filter((recording) => recording.startMs <= ms);
  return started[started.length - 1] || recordings[0];
}

// Where a browser recording spanning [startMs, endMs] stands at `ms`:
// { phase: 'before' | 'during' | 'after', offsetMs }, with `offsetMs` the
// position to show, measured from the recording's start.
export function browserPosition(range, ms) {
  const length = Math.max(0, range.endMs - range.startMs);
  if (ms < range.startMs) return { phase: 'before', offsetMs: 0 };
  if (ms > range.endMs) return { phase: 'after', offsetMs: length };
  return { phase: 'during', offsetMs: ms - range.startMs };
}

// `ms` as m:ss, or h:mm:ss from an hour.
export function formatClock(ms) {
  const seconds = Math.max(0, Math.floor((Number(ms) || 0) / 1000));
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const rest = String(seconds % 60).padStart(2, '0');
  return hours ? `${hours}:${String(minutes).padStart(2, '0')}:${rest}` : `${minutes}:${rest}`;
}

// A duration in its two largest units: "3d 4h", "2h 5m", "4m 10s", "45s".
export function formatSpan(ms) {
  const seconds = Math.max(0, Math.round((Number(ms) || 0) / 1000));
  const units = [['d', 86_400], ['h', 3_600], ['m', 60], ['s', 1]];
  const parts = [];
  let rest = seconds;
  for (const [label, size] of units) {
    const count = Math.floor(rest / size);
    rest -= count * size;
    if (count || parts.length) parts.push(`${count}${label}`);
    if (parts.length === 2) break;
  }
  return parts.filter((part) => !part.startsWith('0')).join(' ') || '0s';
}
