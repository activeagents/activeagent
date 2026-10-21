import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useTheme } from '../../../contexts/ThemeContext';
import { dashboardPath, navigateTo } from '../../../utils/dashboardPath';
import {
  apiErrorMessage,
  codeSessionStatus,
  isCodeSessionActive,
  transcriptRows,
} from '../../../utils/codeSessions.mjs';
import {
  afterQuery,
  composerHint,
  conversationActive,
  conversationLine,
  CONVERSATION_POLL_INTERVAL_MS,
  mergeConversation,
  pendingPersonRequest,
  runnerLabel,
  showBrowserPreference,
  splitForKey,
  splitFromPointer,
  SPLIT_DEFAULT,
  SPLIT_MAX,
  SPLIT_MIN,
  clampSplit,
  turnLine,
} from '../../../utils/codeConversations.mjs';
import { DiffView, StatusBadge, TranscriptRow } from '../CodeSessionPanel';
import LiveView from '../LiveView';

const ORIGIN_LABELS = {
  settings: 'Started from Settings',
  boot_fix: 'Fixing a failed boot',
  evaluation_fix: 'Implementing an evaluation fix',
  chat: 'Chat',
};

// One turn: what the person sent (and the dashboard's note ahead of it),
// then Claude Code's transcript, its outcome, and the diff on demand.
function Turn({ turn, sandboxId, darkMode, muted, strong }) {
  const rows = useMemo(() => transcriptRows(turn.events), [turn.events]);
  const [diff, setDiff] = useState(undefined);
  const status = codeSessionStatus(turn.status);

  const showDiff = async () => {
    if (diff !== undefined) {
      setDiff(undefined);
      return;
    }
    const res = await fetch(`/api/sandboxes/${encodeURIComponent(sandboxId)}/code_sessions/${turn.id}?after=${1e9}`);
    const data = await res.json().catch(() => ({}));
    setDiff(res.ok ? data.code_session?.diff ?? null : null);
  };

  return (
    <li className={`rounded border p-3 space-y-2 ${darkMode ? 'border-gray-700' : 'border-gray-200'}`} data-testid="code-interaction-turn">
      <div className="flex flex-wrap items-center gap-2">
        <StatusBadge tone={status.tone}>{status.label}</StatusBadge>
        <span className={`text-xs ${muted}`}>{turnLine(turn)}</span>
      </div>
      {turn.context_note && (
        <p className={`text-xs italic ${muted}`} title="Sent to Claude Code ahead of the message">Dashboard note: {turn.context_note}</p>
      )}
      <p className={`text-sm whitespace-pre-wrap break-words font-medium ${strong}`}>{turn.prompt}</p>
      <div className="space-y-1">
        {rows.length === 0 && (
          <p className={`text-xs ${muted}`}>{isCodeSessionActive(turn) ? 'Waiting for Claude Code…' : 'No transcript was recorded.'}</p>
        )}
        {rows.map((row) => <TranscriptRow key={row.key} row={row} darkMode={darkMode} muted={muted} strong={strong} />)}
      </div>
      {turn.error_message && <p className={`text-xs ${darkMode ? 'text-red-400' : 'text-red-600'}`}>{turn.error_message}</p>}
      {!isCodeSessionActive(turn) && (
        <div className="space-y-1">
          <button type="button" onClick={showDiff} className={`text-xs underline ${muted}`}>
            {diff === undefined ? 'Show the checkout’s diff after this turn' : 'Hide the diff'}
          </button>
          {diff !== undefined && <DiffView diff={diff} pending={false} muted={muted} darkMode={darkMode} linkButton="underline" />}
        </div>
      )}
    </li>
  );
}

// A Claude Code or Codex conversation as an interaction: its turns, a
// composer that sends the next one, and the sandbox's browser beside them,
// which the person can take over and hand back. A hand-back is reported
// with the next message, so Claude Code knows the page may have changed.
export default function CodeInteraction({ rootId, onBack = null }) {
  const { darkMode } = useTheme();
  const [conversation, setConversation] = useState(null);
  const [error, setError] = useState(null);
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);
  const [handoff, setHandoff] = useState(null);
  const [showBrowser, setShowBrowserState] = useState(initialShowBrowser);
  const held = useRef(null);
  held.current = conversation;
  const composerRef = useRef(null);
  const workspaceRef = useRef(null);
  const transcriptRef = useRef(null);
  const workspaceHeight = useViewportFill(workspaceRef, Boolean(conversation));
  const panelsRef = useRef(null);
  const [split, setSplit] = useState(initialSplit);
  const [dragging, setDragging] = useState(false);
  // Side by side only where the panels fill the window (wide screens).
  const sideBySide = showBrowser && Boolean(workspaceHeight);

  const changeSplit = (value) => {
    setSplit(value);
    rememberSplit(value);
  };

  // Dragging the separator: pointer capture keeps the drag on it even over
  // the live view's frame. Refs, not state, carry the drag between events,
  // so a move that comes before the next render still counts.
  const dragRef = useRef(null);
  const splitRef = useRef(split);
  splitRef.current = split;
  const startDrag = (event) => {
    if (event.button !== 0 || !panelsRef.current) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture?.(event.pointerId);
    dragRef.current = panelsRef.current.getBoundingClientRect();
    setDragging(true);
  };
  const drag = (event) => {
    if (!dragRef.current) return;
    const next = splitFromPointer(event.clientX, dragRef.current);
    splitRef.current = next;
    setSplit(next);
  };
  const endDrag = (event) => {
    if (!dragRef.current) return;
    event.currentTarget.releasePointerCapture?.(event.pointerId);
    dragRef.current = null;
    setDragging(false);
    rememberSplit(splitRef.current);
  };
  const keySplit = (event) => {
    const next = splitForKey(split, event.key);
    if (next === null) return;
    event.preventDefault();
    changeSplit(next);
  };

  // The choice lives in the URL (so a link opens the same layout) and is
  // remembered for the next conversation.
  const setShowBrowser = (next) => {
    setShowBrowserState((open) => {
      const value = typeof next === 'function' ? next(open) : next;
      rememberShowBrowser(value);
      return value;
    });
  };

  const load = useCallback(async () => {
    const query = afterQuery(held.current?.turns);
    const res = await fetch(`/api/interactions/code-${rootId}${query ? `?${query}` : ''}`);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      setError(apiErrorMessage(data, `Could not load the conversation (HTTP ${res.status}).`));
      return;
    }
    setError(null);
    setConversation((current) => mergeConversation(current, data.interaction));
  }, [rootId]);

  useEffect(() => {
    setConversation(null);
    held.current = null;
    void load();
  }, [load]);

  const active = conversationActive(conversation);
  useEffect(() => {
    if (!active) return undefined;
    const timer = setInterval(() => void load(), CONVERSATION_POLL_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [active, load]);

  // Follow the conversation as turns arrive, unless the person scrolled up
  // to read an earlier one.
  const turnCount = conversation?.turns?.length || 0;
  const eventCount = conversation?.turns?.reduce((sum, turn) => sum + (turn.events?.length || 0), 0) || 0;
  const pinnedToBottom = useRef(true);
  useEffect(() => {
    const transcript = transcriptRef.current;
    if (transcript && pinnedToBottom.current) transcript.scrollTop = transcript.scrollHeight;
  }, [turnCount, eventCount, workspaceHeight]);
  const trackPin = () => {
    const transcript = transcriptRef.current;
    if (!transcript) return;
    pinnedToBottom.current = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 48;
  };

  const sandboxId = conversation?.sandbox_session_id;
  const lastTurn = conversation?.turns?.[conversation.turns.length - 1];
  const personRequest = pendingPersonRequest(conversation);
  const browserRunning = conversation?.browser?.status === 'running';

  const send = async (event) => {
    event?.preventDefault();
    const prompt = draft.trim();
    if (!prompt || !sandboxId) return;
    setSending(true);
    setError(null);
    try {
      const res = await fetch(`/api/sandboxes/${encodeURIComponent(sandboxId)}/code_sessions/${rootId}/messages`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt, ...(handoff ? { handoff } : {}) }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `The message was not sent (HTTP ${res.status}).`));
      setDraft('');
      setHandoff(null);
      await load();
    } catch (e) {
      setError(e.message);
    } finally {
      setSending(false);
    }
  };

  const cancel = async () => {
    const running = (conversation?.turns || []).filter(isCodeSessionActive);
    for (const turn of running) {
      // eslint-disable-next-line no-await-in-loop
      await fetch(`/api/sandboxes/${encodeURIComponent(sandboxId)}/code_sessions/${turn.id}/cancel`, { method: 'POST' });
    }
    await load();
  };

  // The person handed the browser back: say so with the next message.
  const handedBack = (report) => {
    setHandoff(report);
    setDraft((current) => current || "I've handed the browser back. ");
    composerRef.current?.focus();
  };

  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const strong = darkMode ? 'text-white' : 'text-gray-900';
  const card = `rounded-lg border p-4 ${darkMode ? 'bg-gray-900 border-gray-700' : 'bg-white border-gray-200'}`;
  const button = `px-3 py-1 text-sm rounded disabled:opacity-50 ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`;
  const primary = 'px-3 py-1 text-sm rounded text-white bg-red-600 hover:bg-red-700 disabled:opacity-50';
  const needsYouClass = `p-2 rounded text-sm border ${darkMode ? 'bg-blue-900/20 border-blue-800 text-blue-200' : 'bg-blue-50 border-blue-200 text-blue-800'}`;

  if (!conversation) {
    return (
      <div className={card} data-testid="code-interaction">
        {error ? <p className={`text-sm ${darkMode ? 'text-red-400' : 'text-red-600'}`}>{error}</p> : <p className={`text-sm ${muted}`}>Loading…</p>}
      </div>
    );
  }

  const status = codeSessionStatus(conversation.status);

  const panelHeader = `flex items-center justify-between gap-2 px-4 py-2 border-b ${darkMode ? 'border-gray-700' : 'border-gray-200'}`;
  const panel = `rounded-lg border flex flex-col min-h-0 ${darkMode ? 'bg-gray-900 border-gray-700' : 'bg-white border-gray-200'}`;
  const iconButton = `px-2 py-0.5 text-xs rounded ${darkMode ? 'text-gray-300 hover:bg-gray-700' : 'text-gray-600 hover:bg-gray-100'}`;

  return (
    <div
      ref={workspaceRef}
      className="flex flex-col gap-3"
      style={workspaceHeight ? { height: workspaceHeight } : undefined}
      data-testid="code-interaction"
    >
      <div className="flex flex-wrap items-start justify-between gap-3 shrink-0">
        <div className="space-y-1">
          {onBack && <button type="button" onClick={onBack} className={`text-xs ${muted}`}>← Interactions</button>}
          <h2 className={`text-xl font-bold ${strong}`}>{conversation.display_name}</h2>
          <div className="flex flex-wrap items-center gap-2">
            <StatusBadge tone={status.tone}>{status.label}</StatusBadge>
            <span className={`text-xs ${muted}`}>{ORIGIN_LABELS[conversation.origin] || conversation.origin} · {conversationLine(conversation)}</span>
            {conversation.project && (
              <a
                href={dashboardPath(`/projects/${conversation.project.id}`)}
                onClick={(event) => { event.preventDefault(); navigateTo(`/projects/${conversation.project.id}`); }}
                className="text-xs underline"
              >
                {conversation.project.name}
              </a>
            )}
          </div>
        </div>
        <div className="flex items-center gap-2">
          {active && <button type="button" onClick={cancel} className={button}>Stop</button>}
          <button
            type="button"
            onClick={() => setShowBrowser((open) => !open)}
            className={button}
            aria-pressed={showBrowser}
            aria-controls={`code-interaction-${rootId}-browser`}
          >
            {showBrowser ? 'Hide browser' : 'Show browser'}
          </button>
        </div>
      </div>

      {personRequest && !showBrowser && (
        <p role="alert" className={`${needsYouClass} shrink-0`}>
          Claude Code needs you: {personRequest.reason}{' '}
          <button type="button" onClick={() => setShowBrowser(true)} className="underline">Show the browser</button>
        </p>
      )}

      {/* Two panels that fill the rest of the window, each scrolling on its
          own: the conversation (composer pinned to its foot) and the
          browser. Stacked, at natural height, on narrow screens. */}
      <div
        ref={panelsRef}
        className={`flex-1 min-h-0 flex flex-col gap-4 ${sideBySide ? 'lg:flex-row lg:gap-0' : ''} ${dragging ? 'select-none cursor-col-resize' : ''}`}
      >
        <section
          className={`${panel} lg:h-full min-w-0`}
          style={sideBySide ? { flex: `0 0 ${split}%` } : undefined}
          aria-label="Conversation"
          id={`code-interaction-${rootId}-conversation`}
        >
          <div className={panelHeader}>
            <span className={`text-sm font-medium ${strong}`}>Conversation</span>
            {!showBrowser && (
              <button type="button" onClick={() => setShowBrowser(true)} className={iconButton}>Show browser ›</button>
            )}
          </div>
          <ol ref={transcriptRef} onScroll={trackPin} className="space-y-3 p-4 flex-1 min-h-0 overflow-y-auto">
            {conversation.turns.map((turn) => (
              <Turn key={turn.id} turn={turn} sandboxId={sandboxId} darkMode={darkMode} muted={muted} strong={strong} />
            ))}
          </ol>

          <form onSubmit={send} className={`space-y-2 p-4 border-t shrink-0 ${darkMode ? 'border-gray-700' : 'border-gray-200'}`}>
            <label htmlFor={`code-interaction-${rootId}-message`} className={`text-xs font-medium ${strong}`}>
              Message {runnerLabel(conversation)}
            </label>
            <textarea
              id={`code-interaction-${rootId}-message`}
              ref={composerRef}
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              rows={3}
              className={`w-full text-sm rounded border p-2 ${darkMode ? 'bg-gray-800 border-gray-600 text-white' : 'bg-white border-gray-300'}`}
              placeholder={lastTurn?.result ? 'Reply, or ask for the next change' : 'What should happen next?'}
            />
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span className={`text-xs ${muted}`} role="status">{composerHint(conversation, { handoff })}</span>
              <button type="submit" className={primary} disabled={sending || !draft.trim()}>{sending ? 'Sending…' : 'Send'}</button>
            </div>
            {error && <p className={`text-xs ${darkMode ? 'text-red-400' : 'text-red-600'}`} role="alert">{error}</p>}
          </form>
        </section>

        {sideBySide && (
          // Drag, or focus and use the arrow keys (Home/End for the limits,
          // Enter or a double-click for half and half).
          <div
            role="separator"
            aria-orientation="vertical"
            aria-label="Resize the conversation and the browser"
            aria-controls={`code-interaction-${rootId}-conversation`}
            aria-valuenow={Math.round(split)}
            aria-valuemin={SPLIT_MIN}
            aria-valuemax={SPLIT_MAX}
            tabIndex={0}
            onPointerDown={startDrag}
            onPointerMove={drag}
            onPointerUp={endDrag}
            onPointerCancel={endDrag}
            onKeyDown={keySplit}
            onDoubleClick={() => changeSplit(SPLIT_DEFAULT)}
            className="group hidden lg:flex w-4 shrink-0 cursor-col-resize items-center justify-center touch-none focus:outline-none"
            data-testid="code-interaction-separator"
          >
            <span
              className={`h-12 w-1 rounded-full transition-colors ${dragging
                ? 'bg-red-500'
                : darkMode ? 'bg-gray-600 group-hover:bg-gray-400 group-focus-visible:bg-red-500' : 'bg-gray-300 group-hover:bg-gray-500 group-focus-visible:bg-red-500'}`}
            />
          </div>
        )}

        {showBrowser && (
          <section
            id={`code-interaction-${rootId}-browser`}
            className={`${panel} lg:h-full min-w-0 flex-1`}
            aria-label="The sandbox’s browser"
            data-testid="code-interaction-browser"
          >
            <div className={panelHeader}>
              <span className={`text-sm font-medium ${strong}`}>The sandbox’s browser</span>
              <button type="button" onClick={() => setShowBrowser(false)} className={iconButton} aria-label="Hide the browser">
                Hide ×
              </button>
            </div>
            <div className="p-4 space-y-2 flex-1 min-h-0 overflow-y-auto">
            {personRequest && (
              <p role="alert" className={needsYouClass}>{runnerLabel(conversation)} needs you: {personRequest.reason}</p>
            )}
            {browserRunning ? (
              <LiveView sessionId={sandboxId} watchOnOpen onHandBack={handedBack} handBackLabel={`Hand back to ${runnerLabel(conversation)}`} />
            ) : (
              <p className={`text-xs ${muted}`}>
                The browser is not running.{' '}
                {conversation.project ? (
                  <a
                    href={dashboardPath(`/projects/${conversation.project.id}?tab=browser`)}
                    onClick={(event) => { event.preventDefault(); navigateTo(`/projects/${conversation.project.id}?tab=browser`); }}
                    className="underline"
                  >
                    Start it from the project
                  </a>
                ) : 'Start it from Settings → Integrations'}
                , and Claude Code reaches it from its next turn.
              </p>
            )}
            </div>
          </section>
        )}
      </div>
    </div>
  );
}

const SHOW_BROWSER_KEY = 'activeagents.codeInteraction.showBrowser';
const SPLIT_KEY = 'activeagents.codeInteraction.split';

function initialSplit() {
  try {
    const stored = window.localStorage.getItem(SPLIT_KEY);
    return stored === null ? SPLIT_DEFAULT : clampSplit(stored);
  } catch {
    return SPLIT_DEFAULT;
  }
}

function rememberSplit(value) {
  try {
    window.localStorage.setItem(SPLIT_KEY, String(value));
  } catch {
    // Storage may be off; the split lasts for this page.
  }
}

function initialShowBrowser() {
  let stored = null;
  try {
    stored = window.localStorage.getItem(SHOW_BROWSER_KEY);
  } catch {
    // Storage may be off; the URL alone decides.
  }
  return showBrowserPreference(window.location.search, stored);
}

function rememberShowBrowser(value) {
  try {
    window.localStorage.setItem(SHOW_BROWSER_KEY, value ? '1' : '0');
  } catch {
    // Storage may be off; the URL still carries the choice.
  }
  const url = new URL(window.location.href);
  url.searchParams.set('browser', value ? '1' : '0');
  window.history.replaceState(window.history.state, '', url);
}

// The height that takes +ref+ from where it starts to the bottom of the
// window, less the dashboard's bottom padding, on wide screens only; null
// on narrow ones, where the panels stack at their natural height. +ready+
// says the element is mounted (it isn't while the conversation loads).
function useViewportFill(ref, ready) {
  const [height, setHeight] = useState(null);
  useLayoutEffect(() => {
    const wide = window.matchMedia('(min-width: 1024px)');
    const measure = () => {
      const el = ref.current;
      if (!el || !wide.matches) {
        setHeight(null);
        return;
      }
      const top = el.getBoundingClientRect().top + window.scrollY;
      setHeight(Math.max(420, Math.floor(window.innerHeight - top - 24)));
    };
    measure();
    window.addEventListener('resize', measure);
    wide.addEventListener('change', measure);
    return () => {
      window.removeEventListener('resize', measure);
      wide.removeEventListener('change', measure);
    };
  }, [ref, ready]);
  return height;
}
