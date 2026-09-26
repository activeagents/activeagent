import React, { useState, useEffect, useCallback, useLayoutEffect, useMemo, useRef } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { timeAgo } from '../../utils/format';
import {
  CODE_SESSION_POLL_INTERVAL_MS,
  apiErrorMessage,
  codeSessionNeverRan,
  codeSessionStatus,
  diffLines,
  diffStats,
  isCodeSessionActive,
  isCodeSessionDiffPending,
  isCodeSessionFinished,
  isCodeSessionSettled,
  mergeEvents,
  pollGivesUp,
  sessionCounts,
  sessionResultLine,
  sessionSummary,
  sessionTitle,
  transcriptRows,
  upsertBy,
} from '../../utils/codeSessions.mjs';

// The composer's limit, as the model validates it.
const MAX_PROMPT_CHARACTERS = 20000;

// Where a transcript or diff is read: a shade apart from the card's rows.
const surfaceStyle = (darkMode) => ({ backgroundColor: darkMode ? '#1a1a1a' : '#ffffff' });

const BADGE_CLASSES = {
  success: { dark: 'bg-green-900/30 text-green-300', light: 'bg-green-50 text-green-700' },
  error: { dark: 'bg-red-900/30 text-red-300', light: 'bg-red-50 text-red-700' },
  progress: { dark: 'bg-amber-900/30 text-amber-300', light: 'bg-amber-50 text-amber-700' },
  neutral: { dark: 'bg-gray-700 text-gray-300', light: 'bg-gray-100 text-gray-600' },
};

// A status as the Integrations cards show it; the tone comes from
// sandboxStatus / codeSessionStatus.
export function StatusBadge({ tone = 'neutral', children }) {
  const { darkMode } = useTheme();
  const classes = BADGE_CLASSES[tone] || BADGE_CLASSES.neutral;
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${darkMode ? classes.dark : classes.light}`}>
      {tone === 'progress' && <span className="mr-1 h-1.5 w-1.5 rounded-full bg-current animate-pulse" />}
      {children}
    </span>
  );
}

// Settings -> Integrations: headless Claude Code sessions in a ready checkout
// sandbox. A prompt starts one; the selected session's stream-json
// transcript is polled incrementally (`?after=N`) until it finishes, then
// its diff is shown. One session runs per checkout at a time.
export default function CodeSessionPanel({ sandbox, claudeCodeConnected, onRecheckConnection }) {
  const { darkMode } = useTheme();
  const base = `/api/sandboxes/${encodeURIComponent(sandbox.session_id)}/code_sessions`;
  const [sessions, setSessions] = useState(null); // summaries, newest first
  const [selectedId, setSelectedId] = useState(null);
  const [detail, setDetail] = useState(null); // the selected session's details, events accumulated
  const [detailError, setDetailError] = useState(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [listTick, setListTick] = useState(0);
  const [prompt, setPrompt] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const [error, setError] = useState(null);
  const transcriptRef = useRef(null);
  const stickToBottom = useRef(true);

  const fetchSessions = useCallback(async () => {
    const res = await fetch(base);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(apiErrorMessage(data, `Could not load Claude Code sessions (HTTP ${res.status}).`));
    return data.code_sessions || [];
  }, [base]);

  // The sandbox's earlier sessions; the one still going (or else the newest)
  // opens.
  useEffect(() => {
    let cancelled = false;
    setSessions(null);
    setSelectedId(null);
    fetchSessions()
      .then((list) => {
        if (cancelled) return;
        setSessions(list);
        const open = list.find(isCodeSessionActive) || list[0];
        setSelectedId((current) => current ?? open?.id ?? null);
      })
      .catch((e) => {
        if (cancelled) return;
        setSessions([]);
        setError(e.message);
      });
    return () => { cancelled = true; };
  }, [fetchSessions]);

  // The selected session: fetched from its first event, then polled for the
  // events after the ones held until it settles. Stops on unmount, on a
  // different selection, once the server says nothing more will be
  // recorded (a cancelled session is finished at once, but its Claude Code
  // may still be stopping, adding events and then its diff), or when
  // pollGivesUp: on a refusal (4xx), or after MAX_POLL_FAILURES failures in
  // a row.
  useEffect(() => {
    if (selectedId == null) return undefined;
    let cancelled = false;
    let timer = null;
    let events = [];
    let failures = 0;
    setDetail(null);
    setDetailError(null);
    stickToBottom.current = true;

    const poll = async () => {
      let again = true;
      let status = null;
      try {
        const res = await fetch(`${base}/${selectedId}?after=${events.length}`);
        status = res.status;
        const data = await res.json().catch(() => ({}));
        if (cancelled) return;
        if (!res.ok) throw new Error(apiErrorMessage(data, `Could not load the session (HTTP ${res.status}).`));
        const session = data.code_session;
        events = mergeEvents(events, session);
        failures = 0;
        setDetailError(null);
        setDetail({ ...session, events });
        setSessions((list) => upsertBy(list || [], sessionSummary(session), 'id'));
        if (isCodeSessionSettled(session)) again = false;
      } catch (e) {
        if (cancelled) return;
        failures += 1;
        setDetailError(e.message);
        if (pollGivesUp(status, failures)) again = false;
      }
      if (again && !cancelled) timer = setTimeout(poll, CODE_SESSION_POLL_INTERVAL_MS);
    };

    poll();
    return () => { cancelled = true; clearTimeout(timer); };
  }, [base, selectedId, reloadTick]);

  // A session still going that is not the one open (another tab started it,
  // or the user opened an older one): refresh the list until it finishes, so
  // the composer unlocks when the checkout is free again.
  const activeSession = (sessions || []).find(isCodeSessionActive) || null;
  const watchedId = activeSession && activeSession.id !== selectedId ? activeSession.id : null;
  // Why the composer is locked: no Claude Code credential, or the checkout
  // is busy with another session.
  const blockedReason = !claudeCodeConnected ? 'not_connected' : activeSession ? 'busy' : null;
  useEffect(() => {
    if (watchedId == null) return undefined;
    let cancelled = false;
    const timer = setTimeout(async () => {
      try {
        const list = await fetchSessions();
        if (!cancelled) setSessions(list);
      } catch (_error) {
        // Tried again on the next tick.
      }
      if (!cancelled) setListTick((tick) => tick + 1);
    }, CODE_SESSION_POLL_INTERVAL_MS * 2);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [watchedId, listTick, fetchSessions]);

  const rows = useMemo(() => transcriptRows(detail?.events), [detail?.events]);

  // Follows the transcript as it grows, unless it was scrolled up to read.
  useLayoutEffect(() => {
    const el = transcriptRef.current;
    if (el && stickToBottom.current) el.scrollTop = el.scrollHeight;
  }, [rows.length]);

  const onTranscriptScroll = (e) => {
    const el = e.currentTarget;
    stickToBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  };

  const run = async () => {
    const text = prompt.trim();
    if (!text || blockedReason || submitting) return;
    setSubmitting(true);
    setError(null);
    try {
      const res = await fetch(base, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt: text }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        // 409: a session is already going in this checkout. Open it.
        if (data.code_session) {
          setSessions((list) => upsertBy(list || [], data.code_session, 'id'));
          setSelectedId(data.code_session.id);
        }
        throw new Error(apiErrorMessage(data, `Could not start Claude Code (HTTP ${res.status}).`));
      }
      setSessions((list) => upsertBy(list || [], data.code_session, 'id'));
      setSelectedId(data.code_session.id);
      setPrompt('');
    } catch (e) {
      setError(e.message);
    } finally {
      setSubmitting(false);
    }
  };

  const cancel = async (session) => {
    setCancelling(true);
    setError(null);
    try {
      const res = await fetch(`${base}/${session.id}/cancel`, { method: 'POST' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `Could not cancel the session (HTTP ${res.status}).`));
      setSessions((list) => upsertBy(list || [], data.code_session, 'id'));
      setDetail((current) => (current && current.id === data.code_session.id ? { ...current, ...data.code_session } : current));
    } catch (e) {
      setError(e.message);
    } finally {
      setCancelling(false);
    }
  };

  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const strong = darkMode ? 'text-white' : 'text-gray-900';
  const border = darkMode ? 'border-gray-700' : 'border-gray-200';
  const secondaryButton = `px-3 py-1 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`;
  const linkButton = `underline ${darkMode ? 'text-gray-300 hover:text-white' : 'text-gray-700 hover:text-gray-900'}`;
  const errorBox = `p-2 rounded text-xs border ${darkMode ? 'bg-red-900/20 border-red-800 text-red-300' : 'bg-red-50 border-red-200 text-red-700'}`;

  const selected = detail && detail.id === selectedId ? detail : (sessions || []).find((s) => s.id === selectedId) || null;

  return (
    <div className={`mt-2 p-3 rounded-lg border space-y-3 ${border}`}>
      <div className="flex items-center justify-between">
        <p className={`text-sm font-medium ${strong}`}>Claude Code</p>
        <p className={`text-xs ${muted}`}>Edits this checkout; nothing is committed or pushed.</p>
      </div>

      <div className="space-y-2">
        <textarea
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) run(); }}
          rows={3}
          maxLength={MAX_PROMPT_CHARACTERS}
          // A busy checkout still takes a draft of the next prompt.
          disabled={blockedReason === 'not_connected' || submitting}
          placeholder="What should Claude Code do in this checkout?"
          className={`w-full px-3 py-2 border rounded-lg text-sm disabled:opacity-60 ${darkMode ? 'bg-gray-800 border-gray-700 text-white placeholder-gray-500' : 'bg-white border-gray-300 text-gray-900'}`}
        />
        <div className="flex items-center justify-between gap-3">
          <p className={`text-xs ${muted}`}>
            {blockedReason === 'not_connected' && (
              <>
                Connect Claude Code below to run sessions in this checkout.{' '}
                {onRecheckConnection && <button type="button" onClick={onRecheckConnection} className={linkButton}>Check again</button>}
              </>
            )}
            {blockedReason === 'busy' && (
              <>
                A session is {activeSession.status} in this checkout; wait for it to finish or cancel it.{' '}
                {activeSession.id !== selectedId && (
                  <button type="button" onClick={() => setSelectedId(activeSession.id)} className={linkButton}>Show it</button>
                )}
              </>
            )}
          </p>
          <button
            type="button"
            onClick={run}
            disabled={Boolean(blockedReason) || submitting || !prompt.trim()}
            className="shrink-0 px-3 py-1 text-sm bg-red-500 text-white rounded hover:bg-red-600 disabled:opacity-50"
          >
            {submitting ? 'Starting…' : 'Run Claude Code'}
          </button>
        </div>
        {error && <div className={errorBox}>{error}</div>}
      </div>

      {sessions && sessions.length > 0 && (
        <div className="space-y-1">
          <p className={`text-xs font-medium uppercase tracking-wide ${muted}`}>Sessions</p>
          <div className="max-h-40 overflow-y-auto space-y-1">
            {sessions.map((session) => {
              const { label, tone } = codeSessionStatus(session.status);
              const isSelected = session.id === selectedId;
              return (
                <button
                  key={session.id}
                  type="button"
                  title={sessionResultLine(session)}
                  onClick={() => (isSelected ? setReloadTick((tick) => tick + 1) : setSelectedId(session.id))}
                  className={`w-full text-left px-2 py-1.5 rounded flex items-center gap-2 text-sm ${isSelected
                    ? (darkMode ? 'bg-gray-700' : 'bg-gray-200')
                    : (darkMode ? 'hover:bg-gray-800' : 'hover:bg-gray-100')}`}
                >
                  <StatusBadge tone={tone}>{label}</StatusBadge>
                  <span className={`flex-1 truncate ${strong}`}>{sessionTitle(session.prompt)}</span>
                  <span className={`shrink-0 text-xs ${muted}`}>{timeAgo(session.created_at)}</span>
                </button>
              );
            })}
          </div>
        </div>
      )}
      {sessions === null && <p className={`text-xs ${muted}`}>Loading sessions…</p>}

      {selected && (
        <SessionDetail
          session={selected}
          rows={rows}
          loaded={Boolean(detail && detail.id === selected.id)}
          detailError={detailError}
          cancelling={cancelling}
          onCancel={() => cancel(selected)}
          onReload={() => setReloadTick((tick) => tick + 1)}
          transcriptRef={transcriptRef}
          onTranscriptScroll={onTranscriptScroll}
          classes={{ muted, strong, border, secondaryButton, linkButton, errorBox }}
        />
      )}
    </div>
  );
}

function SessionDetail({ session, rows, loaded, detailError, cancelling, onCancel, onReload, transcriptRef, onTranscriptScroll, classes }) {
  const { darkMode } = useTheme();
  const { muted, strong, border, secondaryButton, linkButton, errorBox } = classes;
  const { label, tone } = codeSessionStatus(session.status);
  const active = isCodeSessionActive(session);
  const finished = isCodeSessionFinished(session);
  // Cancelled before Claude Code ran (in the queue, or refused by the
  // backend once cancelled): the server settled it with no diff, and no
  // transcript or diff will ever be recorded.
  const neverStarted = codeSessionNeverRan(session);
  const dropped = Number(session.dropped_events_count) || 0;

  return (
    <div className={`pt-3 border-t space-y-2 ${border}`}>
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2 min-w-0">
          <StatusBadge tone={tone}>{label}</StatusBadge>
          <span className={`text-xs truncate ${muted}`}>
            {[sessionCounts(session), session.model].filter(Boolean).join(' · ')}
          </span>
        </div>
        {active && (
          <button type="button" onClick={onCancel} disabled={cancelling} className={`${secondaryButton} shrink-0 disabled:opacity-50`}>
            {cancelling ? 'Cancelling…' : 'Cancel'}
          </button>
        )}
      </div>

      <p className={`text-xs whitespace-pre-wrap break-words max-h-24 overflow-y-auto ${muted}`}>{session.prompt}</p>

      {detailError && <div className={errorBox}>{detailError}</div>}

      <div
        ref={transcriptRef}
        onScroll={onTranscriptScroll}
        className="max-h-96 overflow-y-auto rounded p-2 space-y-1.5"
        style={surfaceStyle(darkMode)}
      >
        {!loaded && <p className={`text-xs ${muted}`}>Loading transcript…</p>}
        {loaded && rows.length === 0 && (
          <p className={`text-xs ${muted}`}>
            {session.status === 'queued' ? 'Waiting for the sandbox to start Claude Code…'
              : active ? 'Claude Code is starting…'
                : neverStarted ? 'Cancelled before Claude Code started.' : 'No transcript was recorded.'}
          </p>
        )}
        {rows.map((row) => <TranscriptRow key={row.key} row={row} darkMode={darkMode} muted={muted} strong={strong} />)}
        {dropped > 0 && (
          <p className={`text-xs italic ${muted}`}>
            {dropped} later event{dropped === 1 ? ' was' : 's were'} not kept: a transcript keeps its first 1,000.
          </p>
        )}
      </div>

      {session.error_message && (
        <pre className={`${errorBox} whitespace-pre-wrap break-words font-mono max-h-48 overflow-y-auto`}>{session.error_message}</pre>
      )}

      {finished && loaded && (
        <DiffView
          diff={session.diff}
          // The server's word: a session stopped mid-run has its diff
          // taken once its Claude Code has stopped.
          pending={isCodeSessionDiffPending(session)}
          onReload={onReload}
          muted={muted}
          linkButton={linkButton}
          darkMode={darkMode}
        />
      )}
    </div>
  );
}

function TranscriptRow({ row, darkMode, muted, strong }) {
  const nested = row.nested ? `ml-4 pl-2 border-l ${darkMode ? 'border-gray-700' : 'border-gray-200'}` : '';

  switch (row.kind) {
    case 'text':
      return <p className={`text-sm whitespace-pre-wrap break-words ${strong} ${nested}`}>{row.text}</p>;
    case 'user_text':
      return <p className={`text-sm whitespace-pre-wrap break-words ${muted} ${nested}`}>{row.text}</p>;
    case 'thinking':
      return <p className={`text-xs italic whitespace-pre-wrap break-words line-clamp-3 ${muted} ${nested}`}>{row.text}</p>;
    case 'tool_use':
      return (
        <p className={`text-xs font-mono break-words ${nested}`}>
          <span className={`font-semibold ${darkMode ? 'text-blue-300' : 'text-blue-700'}`}>{row.name}</span>
          {row.summary && <span className={muted}> {row.summary}</span>}
        </p>
      );
    case 'tool_result':
      return (
        <pre
          className={`ml-4 text-xs font-mono whitespace-pre-wrap break-words ${row.isError
            ? (darkMode ? 'text-red-400' : 'text-red-600')
            : muted} ${nested}`}
          title={row.name ? `${row.name} result` : undefined}
        >
          {row.text || '(no output)'}
        </pre>
      );
    case 'result':
      return (
        <p className={`text-sm font-medium ${row.tone === 'error'
          ? (darkMode ? 'text-red-400' : 'text-red-600')
          : (darkMode ? 'text-green-400' : 'text-green-600')}`}
        >
          {row.text}
        </p>
      );
    case 'system':
      return <p className={`text-xs ${muted}`}>{row.text}</p>;
    case 'raw':
      return <pre className={`text-xs font-mono whitespace-pre-wrap break-words ${muted} ${nested}`}>{row.text}</pre>;
    default:
      return (
        <pre className={`text-xs font-mono whitespace-pre-wrap break-words ${muted} ${nested}`}>
          [{row.label}] {row.text}
        </pre>
      );
  }
}

const DIFF_LINE_CLASSES = {
  add: { dark: 'text-green-400', light: 'text-green-700' },
  del: { dark: 'text-red-400', light: 'text-red-700' },
  hunk: { dark: 'text-blue-300', light: 'text-blue-700' },
  meta: { dark: 'text-gray-400 font-semibold', light: 'text-gray-500 font-semibold' },
  context: { dark: 'text-gray-300', light: 'text-gray-700' },
};

function DiffView({ diff, pending, onReload, muted, linkButton, darkMode }) {
  const lines = useMemo(() => diffLines(diff), [diff]);

  if (diff == null) {
    // A session cancelled while running has its diff taken once its process
    // has stopped, which can land after the cancel did.
    return pending ? (
      <p className={`text-xs ${muted}`}>
        The diff is recorded once Claude Code has stopped.{' '}
        <button type="button" onClick={onReload} className={linkButton}>Refresh</button>
      </p>
    ) : <p className={`text-xs ${muted}`}>No diff was recorded.</p>;
  }
  if (lines.length === 0) return <p className={`text-xs ${muted}`}>No changes in the checkout.</p>;

  return (
    <div className="space-y-1">
      <p className={`text-xs ${muted}`}>Diff · {diffStats(diff)}</p>
      <pre className="max-h-96 overflow-auto rounded p-2 text-xs font-mono" style={surfaceStyle(darkMode)}>
        {lines.map((line, index) => {
          const tone = DIFF_LINE_CLASSES[line.kind] || DIFF_LINE_CLASSES.context;
          // A diff's lines have no identity but their position.
          return <div key={index} className={darkMode ? tone.dark : tone.light}>{line.text || ' '}</div>;
        })}
      </pre>
    </div>
  );
}
