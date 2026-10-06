import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Badge, Button, Card, Chip, MicroLabel, MONO } from './primitives';
import ReplayScrubber, { LANE_ROWS } from './replay/ReplayScrubber';
import ReplayTranscript from './replay/ReplayTranscript';
import ReplayEntryDetail from './replay/ReplayEntryDetail';
import ReplayBrowserPane from './replay/ReplayBrowserPane';
import useReplayClock from '../../hooks/useReplayClock';
import {
  LANES, axisToTime, browserRecordings, entryIndexAt, formatClock, formatSpan, mergeLanes, playbackAxis, sessionSpans,
  stepTime, timeToAxis,
} from '../../utils/replayTimeline.mjs';

// Replays one session from its timeline (GET .../timeline, see
// SessionTimeline): its messages, model calls and tool calls on one time
// axis, and beneath them its browser when one was recorded. A session with
// no recording still replays from its lanes.

const SPEEDS = [0.5, 1, 2, 4, 8, 16];

const KIND_TITLES = {
  context: 'Conversation',
  run: 'Run',
  scenario_result: 'Evaluation replay',
  recording: 'Recording',
};

function timelinePath(kind, id) {
  const session = encodeURIComponent(id);
  return kind === 'recording' ? `/api/session_recordings/${session}/timeline` : `/api/sessions/${kind}/${session}/timeline`;
}

function laneCounts(entries) {
  return entries.reduce((counts, entry) => ({ ...counts, [entry.lane]: (counts[entry.lane] || 0) + 1 }), {});
}

function SessionReplay({ kind, id, timeline, onBack, handoff }) {
  const entries = useMemo(() => mergeLanes(timeline.lanes), [timeline]);
  const recordings = useMemo(() => browserRecordings(timeline.recordings), [timeline]);
  const axis = useMemo(() => playbackAxis(sessionSpans(entries, recordings)), [entries, recordings]);
  const clock = useReplayClock(axis);
  const { seek, pause } = clock;

  const [visibleLanes, setVisibleLanes] = useState(() => new Set(LANES));
  const [selectedId, setSelectedId] = useState(null);

  const time = axisToTime(axis, clock.position) ?? axis.startMs;
  const shown = useMemo(() => entries.filter((entry) => visibleLanes.has(entry.lane)), [entries, visibleLanes]);
  const current = entries[entryIndexAt(entries, time)] || null;
  const currentShownId = shown[entryIndexAt(shown, time)]?.id ?? null;
  const selected = entries.find((entry) => entry.id === selectedId) || current;
  const counts = useMemo(() => laneCounts(entries), [entries]);

  const choose = useCallback((entry) => {
    pause();
    setSelectedId(entry.id);
    seek(timeToAxis(axis, entry.startMs));
  }, [axis, pause, seek]);

  const step = (direction) => {
    const target = stepTime(shown, time, direction);
    if (target === null) return;
    pause();
    setSelectedId(null);
    seek(timeToAxis(axis, target));
  };

  const togglePlay = () => {
    setSelectedId(null);
    clock.togglePlay();
  };

  const toggleLane = (lane) => setVisibleLanes((lanes) => {
    const next = new Set(lanes);
    if (next.has(lane)) next.delete(lane);
    else next.add(lane);
    return next;
  });

  const session = timeline.session || {};
  const empty = entries.length === 0 && recordings.length === 0;

  return (
    <div data-testid="session-replay" style={{ display: 'flex', flexDirection: 'column', gap: 16, maxWidth: 1400 }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12, flexWrap: 'wrap' }}>
        <div style={{ minWidth: 0 }}>
          <Button variant="ghost" size="sm" onClick={onBack} style={{ padding: '2px 0', marginBottom: 6 }}>&lt;- Sessions</Button>
          <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>
            {KIND_TITLES[kind] || 'Session'} #{id}
          </h1>
          <div style={{ marginTop: 4, display: 'flex', gap: 12, flexWrap: 'wrap', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
            {session.started_at && <span title={session.started_at}>started {new Date(session.started_at).toLocaleString()}</span>}
            {axis.startMs !== null && <span>{formatSpan(axis.endMs - axis.startMs)} long</span>}
            <span>{counts.message || 0} messages · {counts.llm || 0} model calls · {counts.tool || 0} tool calls</span>
            {recordings.length > 0 && <span>browser recorded</span>}
          </div>
        </div>
        <div style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignItems: 'center' }}>
          {session.truncated && <Badge tone="warning" title="Each lane holds its earliest 2,000 entries">truncated</Badge>}
          {handoff}
        </div>
      </div>

      {empty ? (
        <Card testId="replay-empty">
          <div style={{ fontSize: 14, color: 'var(--color-text-primary)' }}>Nothing to replay yet.</div>
          <div style={{ fontSize: 13, color: 'var(--color-text-secondary)', marginTop: 6 }}>
            This session has no messages, model calls, tool calls or browser events.
          </div>
        </Card>
      ) : (
        <>
          <Card padding={14} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div data-testid="replay-controls" style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
              <Button size="sm" testId="replay-step-back" title="Previous entry" onClick={() => step(-1)}>|&lt;</Button>
              <Button size="sm" variant="primary" testId="replay-play" onClick={togglePlay} style={{ minWidth: 72 }}>
                {clock.playing ? 'Pause' : 'Play'}
              </Button>
              <Button size="sm" testId="replay-step-forward" title="Next entry" onClick={() => step(1)}>&gt;|</Button>
              <select
                aria-label="Playback speed"
                value={clock.speed}
                onChange={(event) => clock.setSpeed(Number(event.target.value))}
                style={{ padding: '6px 8px', borderRadius: 8, fontFamily: MONO, fontSize: 12, background: 'var(--color-card)', border: '1px solid var(--color-border-strong)', color: 'var(--color-text-primary)' }}
              >
                {SPEEDS.map((speed) => <option key={speed} value={speed}>{speed}x</option>)}
              </select>
              <span data-testid="replay-clock" style={{ marginLeft: 8, fontFamily: MONO, fontSize: 12, color: 'var(--color-text-primary)' }}>
                {formatClock(time - axis.startMs)}
              </span>
              <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }} title="Idle stretches longer than 10 seconds play as one second">
                {Number.isFinite(time) ? new Date(time).toLocaleTimeString() : ''}
              </span>
            </div>
            <ReplayScrubber axis={axis} entries={entries} recordings={recordings} position={clock.position} onSeek={seek} />
          </Card>

          <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 3fr) minmax(0, 2fr)', gap: 16, alignItems: 'start' }}>
            <Card padding={0} style={{ overflow: 'hidden' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '10px 12px', borderBottom: '1px solid var(--color-border-light)', flexWrap: 'wrap' }}>
                <MicroLabel style={{ marginRight: 6 }}>timeline</MicroLabel>
                {LANE_ROWS.map((row) => (
                  <Chip key={row.lane} mono selected={visibleLanes.has(row.lane)} onClick={() => toggleLane(row.lane)}>
                    {row.label} {counts[row.lane] || 0}
                  </Chip>
                ))}
              </div>
              <ReplayTranscript
                entries={shown}
                startMs={axis.startMs}
                currentId={currentShownId}
                selectedId={selectedId}
                playing={clock.playing}
                onChoose={choose}
              />
            </Card>
            <Card padding={0}>
              <ReplayEntryDetail entry={selected} />
            </Card>
          </div>

          {recordings.length > 0 && (
            <Card padding={14}>
              <ReplayBrowserPane
                recordings={recordings}
                time={time}
                sessionStartMs={axis.startMs}
                playing={clock.playing}
                speed={clock.speed}
                seekVersion={clock.seekVersion}
              />
            </Card>
          )}
        </>
      )}
    </div>
  );
}

// `kind` and `id` name the session (see sessionReplayPath). A recording
// that carries handoff state offers Take over session, and `onHandoff`
// receives the handoff response.
export default function SessionReplayView({ kind, id, onBack, onHandoff }) {
  const [state, setState] = useState({ status: 'loading' });
  const [canHandOff, setCanHandOff] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setState({ status: 'loading' });
    fetch(timelinePath(kind, id))
      .then(async (response) => {
        if (cancelled) return;
        if (response.status === 404) return setState({ status: 'missing' });
        const body = await response.json().catch(() => ({}));
        if (!response.ok) return setState({ status: 'error', message: body.error || `Could not load this session (HTTP ${response.status})` });
        return setState({ status: 'ready', timeline: body.timeline || {} });
      })
      .catch(() => {
        if (!cancelled) setState({ status: 'error', message: 'Could not load this session: the request did not complete' });
      });

    if (kind === 'recording') {
      fetch(`/api/session_recordings/${encodeURIComponent(id)}`)
        .then((response) => (response.ok ? response.json() : null))
        .then((body) => { if (!cancelled) setCanHandOff(Boolean(body?.recording?.handoff_state)); })
        .catch(() => {});
    }
    return () => { cancelled = true; };
  }, [kind, id]);

  const handOff = async () => {
    const response = await fetch(`/api/session_recordings/${encodeURIComponent(id)}/handoff`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    });
    if (response.ok) onHandoff?.(await response.json());
  };

  if (state.status === 'ready') {
    return (
      <SessionReplay
        kind={kind}
        id={id}
        timeline={state.timeline}
        onBack={onBack}
        handoff={canHandOff && <Button size="sm" variant="primary" testId="replay-take-over" onClick={handOff}>Take over session</Button>}
      />
    );
  }

  const message = state.status === 'loading' ? 'loading the session…'
    : state.status === 'missing' ? 'This session does not exist, or you cannot open it.'
      : state.message;

  return (
    <div data-testid="session-replay" style={{ display: 'flex', flexDirection: 'column', gap: 12, maxWidth: 1400 }}>
      <Button variant="ghost" size="sm" onClick={onBack} style={{ padding: '2px 0', alignSelf: 'flex-start' }}>&lt;- Sessions</Button>
      <Card testId={`replay-${state.status}`}>
        <div style={{ fontSize: 13, color: state.status === 'loading' ? 'var(--color-text-muted)' : 'var(--color-text-primary)' }}>{message}</div>
      </Card>
    </div>
  );
}
