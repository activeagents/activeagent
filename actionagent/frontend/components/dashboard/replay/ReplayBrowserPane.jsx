import React, { useEffect, useRef, useState } from 'react';
import { MicroLabel, MONO } from '../primitives';
import { dashboardPath } from '../../../utils/dashboardPath';
import { PLAYER_FRAME_PATH, PLAYER_FRAME_SANDBOX, isPlayerMessage, playerMessage } from '../../../utils/replayFrame.mjs';
import { browserPosition, formatClock, recordingAt } from '../../../utils/replayTimeline.mjs';
import { loadRrwebEvents } from '../../../utils/replayEntries.mjs';

// The session's browser, replayed in the session player frame
// (SessionPlayerController) in step with the rest of the replay. The
// recording shown is the one the session's current moment falls in. Its
// events are read here, over the dashboard's API, and posted to the frame.

async function fetchJson(path) {
  const response = await fetch(path);
  if (!response.ok) throw new Error(`Could not load the browser recording (HTTP ${response.status})`);
  return response.json();
}

const STATUS_TEXT = {
  loading: 'loading the browser recording…',
  empty: 'this recording has too few browser events to replay',
  truncated: 'showing the start of a long recording',
};

export default function ReplayBrowserPane({ recordings, time, sessionStartMs, playing, speed, seekVersion }) {
  const frame = useRef(null);
  const loadToken = useRef(null);
  const [ready, setReady] = useState(false);
  const [loadedToken, setLoadedToken] = useState(null);
  const [status, setStatus] = useState({ state: 'loading' });

  const recording = recordingAt(recordings, time);
  const recordingId = recording?.id;
  const loaded = loadedToken !== null && loadedToken === loadToken.current;
  const position = recording ? browserPosition(recording, time) : null;

  const post = (type, payload) => {
    frame.current?.contentWindow?.postMessage(playerMessage(type, payload), window.location.origin);
  };

  useEffect(() => {
    const onMessage = (event) => {
      if (!isPlayerMessage(event, frame.current?.contentWindow, window.location.origin)) return;

      const { type } = event.data;
      if (type === 'ready') setReady(true);
      else if (type === 'loaded') setLoadedToken(event.data.token);
      else if (type === 'error') setStatus({ state: 'error', message: event.data.message });
    };
    window.addEventListener('message', onMessage);
    return () => window.removeEventListener('message', onMessage);
  }, []);

  // rrweb needs at least two events to build a replayer, so the first
  // pages are held until they add up to two.
  useEffect(() => {
    if (!ready || recordingId == null) return undefined;

    let cancelled = false;
    let pending = [];
    const token = `${recordingId}:${Date.now()}`;
    loadToken.current = token;
    setLoadedToken(null);
    setStatus({ state: 'loading' });

    loadRrwebEvents(recordingId, {
      fetchPage: fetchJson,
      isCancelled: () => cancelled,
      onEvents: (events) => {
        if (pending === null) {
          post('append', { events });
          return;
        }
        pending = pending.concat(events);
        if (pending.length < 2) return;
        post('load', { events: pending, token });
        pending = null;
      },
    })
      .then(({ truncated }) => {
        if (cancelled) return;
        if (pending !== null) setStatus({ state: 'empty' });
        else setStatus({ state: truncated ? 'truncated' : 'ready' });
      })
      .catch((error) => {
        if (!cancelled) setStatus({ state: 'error', message: error.message });
      });
    return () => { cancelled = true; };
  }, [ready, recordingId]);

  // Moves the replay whenever the session jumps, starts or stops, or enters
  // or leaves this recording. Between those the frame plays on its own
  // clock, so the session's position is read when one of them happens.
  const phase = position?.phase;
  useEffect(() => {
    if (!loaded || !position) return;
    post('seek', { offset: position.offsetMs, playing: playing && phase === 'during' });
  }, [loaded, seekVersion, playing, phase]);

  useEffect(() => {
    if (loaded) post('speed', { speed });
  }, [loaded, speed]);

  const note = status.state === 'error' ? status.message
    : phase === 'before' ? `the browser recording starts at ${formatClock(recording.startMs - sessionStartMs)}`
      : STATUS_TEXT[status.state];

  return (
    <div data-testid="replay-browser" style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <MicroLabel>browser</MicroLabel>
        {recording && (
          <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
            {recording.name || `recording ${recording.id}`}
            {recordings.length > 1 ? ` · ${recordings.indexOf(recording) + 1} of ${recordings.length}` : ''}
          </span>
        )}
        {note && (
          <span style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 11, color: status.state === 'error' ? 'var(--color-error-text)' : 'var(--color-text-muted)' }}>
            {note}
          </span>
        )}
      </div>
      <iframe
        ref={frame}
        title="Browser recording"
        src={dashboardPath(PLAYER_FRAME_PATH)}
        sandbox={PLAYER_FRAME_SANDBOX}
        referrerPolicy="no-referrer"
        onLoad={() => setReady(true)}
        style={{
          width: '100%', height: 480, border: '1px solid var(--color-border-light)', borderRadius: 10,
          background: 'var(--color-background)', opacity: phase === 'before' ? 0.4 : 1,
        }}
      />
    </div>
  );
}
