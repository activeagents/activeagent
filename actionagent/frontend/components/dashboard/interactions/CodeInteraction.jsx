import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
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
  const [showBrowser, setShowBrowser] = useState(() => new URLSearchParams(window.location.search).get('browser') === '1');
  const held = useRef(null);
  held.current = conversation;
  const composerRef = useRef(null);

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

  return (
    <div className="space-y-4" data-testid="code-interaction">
      <div className="flex flex-wrap items-start justify-between gap-3">
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
          <button type="button" onClick={() => setShowBrowser((open) => !open)} className={button} aria-pressed={showBrowser}>
            {showBrowser ? 'Hide browser' : 'Browser'}
          </button>
        </div>
      </div>

      {personRequest && !showBrowser && (
        <p role="alert" className={needsYouClass}>
          Claude Code needs you: {personRequest.reason}{' '}
          <button type="button" onClick={() => setShowBrowser(true)} className="underline">Open the browser</button>
        </p>
      )}

      {/* items-start: a stretched grid item has no room to stick in. */}
      <div className={showBrowser ? 'grid gap-4 lg:grid-cols-2 items-start' : ''}>
        <div className="space-y-3">
          <ol className="space-y-3">
            {conversation.turns.map((turn) => (
              <Turn key={turn.id} turn={turn} sandboxId={sandboxId} darkMode={darkMode} muted={muted} strong={strong} />
            ))}
          </ol>

          <form onSubmit={send} className={`${card} space-y-2`}>
            <label htmlFor={`code-interaction-${rootId}-message`} className={`text-xs font-medium ${strong}`}>
              Message {conversation.runner === 'codex' ? 'Codex' : 'Claude Code'}
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
        </div>

        {showBrowser && (
          // Sticky beside a long transcript, so Take over and Hand back stay
          // in view; scrolls on its own when taller than the screen.
          <div
            className={`${card} space-y-2 lg:sticky lg:top-4 lg:max-h-[calc(100vh-2rem)] lg:overflow-y-auto`}
            data-testid="code-interaction-browser"
          >
            {personRequest && (
              <p role="alert" className={needsYouClass}>Claude Code needs you: {personRequest.reason}</p>
            )}
            <p className={`text-sm font-medium ${strong}`}>The sandbox’s browser</p>
            {browserRunning ? (
              <LiveView sessionId={sandboxId} watchOnOpen onHandBack={handedBack} handBackLabel="Hand back to Claude Code" />
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
        )}
      </div>
    </div>
  );
}
