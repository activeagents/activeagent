import React, { useState, useEffect, useRef } from 'react';
import AgentAvatar from '../AgentAvatar';
import { TYPOGRAPHY } from '../../utils/designTokens';
import { startCheckout } from '../../utils/checkout';
import { useTheme } from '../../contexts/ThemeContext';
import { paletteFor, ACCENT } from '../../utils/dashboardTheme';
import { dashboardPath } from '../../utils/dashboardPath';
import { attachmentKind } from '../../utils/attachments';
import { Badge, Button } from './AgentEditor';
import InteractionStream, { roleBubble, streamPreStyle, AttachmentChips } from './InteractionStream';
import Markdown from './Markdown';

// The runner is a conversation workbench: an operator tests the agent as a
// user would, against a persisted conversation (a solid_agent context) that
// is also the editable history — messages can be edited, deleted, or seeded
// without a run, and files ride along with the prompt. Assistant replies
// render markdown and generative UI; a form or choice in that UI sends the
// next user message.

// Feed event kinds mapped onto the shared stream chip palette so streamed
// run output matches the Interactions/Traces visual language.
const EVENT_BUBBLES = {
  llm: { role: 'assistant', label: 'LLM' },
  tool: { role: 'tool', label: 'Tool' },
  agent: { role: 'developer', label: 'Agent' },
  mcp: { role: 'system', label: 'MCP' },
};

const eventBubble = (kind, darkMode) => {
  const mapping = EVENT_BUBBLES[kind] || { role: kind, label: kind };
  return { ...roleBubble(mapping.role, darkMode), label: mapping.label };
};

const STATUS_TONE = { complete: 'success', failed: 'error', running: 'info', pending: 'warning', cancelled: 'neutral' };

const EXAMPLE_PROMPTS = [
  'Hello, what can you help me with?',
  "Show me a dashboard of last quarter's sales",
  'List the files in the current directory',
  'Explain how this code works',
];

const CONVERSATION_ROLES = ['user', 'assistant', 'tool'];
const POLL_INTERVAL_MS = 1200;
const POLL_TIMEOUT_MS = 10 * 60 * 1000;

const formatDuration = (ms) => {
  if (!ms) return '-';
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(2)}s`;
};

const prettyEventJson = (value) => {
  if (!value) return null;
  try {
    return JSON.stringify(JSON.parse(value), null, 2);
  } catch {
    return value;
  }
};

// Pair started/done progress events by eid for the live activity feed.
// The started event's detail is the call's input (tool arguments); the
// finishing event's detail is its output (result preview or error).
const activityFeed = (run) => {
  const byEid = new Map();
  (run?.logs || []).filter((entry) => entry.eid).forEach((event) => {
    const entry = byEid.get(event.eid) || { eid: event.eid };
    if (event.status === 'started') {
      Object.assign(entry, event, { input: event.detail, output: entry.output });
    } else {
      Object.assign(entry, event, { input: entry.input, output: event.detail });
    }
    byEid.set(event.eid, entry);
  });
  return [...byEid.values()];
};

const contextIdOf = (run) => run?.context_id ?? run?.output_metadata?.context_id ?? null;

const parseJson = (response) => response.json().catch(() => ({}));

const Chevron = ({ open, color }) => (
  <svg
    className={`w-3.5 h-3.5 mt-1 flex-shrink-0 transition-transform ${open ? 'rotate-180' : ''}`}
    fill="none" stroke="currentColor" viewBox="0 0 24 24"
    style={{ color }}
  >
    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
  </svg>
);

// Live activity feed — same chip/expansion design as the Interactions
// stream, one row per llm/tool/agent call. Click a row to inspect the
// call's input and output.
function ActivityFeed({ run, darkMode, colors, expanded, onToggle }) {
  const events = activityFeed(run);
  const preStyle = streamPreStyle(darkMode);
  return (
    <div data-testid="runner-activity" className="space-y-2">
      {events.map((event) => {
        const isExpanded = !!expanded[event.eid];
        const expandable = Boolean(event.input || event.output);
        const bubble = eventBubble(event.kind, darkMode);
        return (
          <div key={event.eid} data-testid="runner-activity-event">
            <div
              className={`flex gap-3 items-start rounded-lg -mx-2 px-2 py-1 ${expandable ? 'cursor-pointer' : ''}`}
              onClick={expandable ? () => onToggle(event.eid) : undefined}
              title={expandable ? 'Click to inspect input/output' : undefined}
              style={isExpanded ? { background: darkMode ? 'rgba(255,255,255,0.04)' : 'rgba(0,0,0,0.03)' } : {}}
            >
              <span
                className="px-2 py-0.5 rounded text-xs font-medium flex-shrink-0 mt-0.5"
                style={{ background: bubble.background, color: bubble.color, minWidth: '72px', textAlign: 'center' }}
              >
                {bubble.label}
              </span>
              <div className="min-w-0 flex-1">
                <div className="text-sm break-words" style={{ color: colors.textPrimary }}>
                  {event.label}
                  {event.output && !isExpanded && (
                    <span style={{ color: colors.textMuted }}> “{event.output.slice(0, 160)}{event.output.length > 160 ? '…' : ''}”</span>
                  )}
                </div>
                <div className="text-xs mt-0.5 font-mono flex items-center gap-2 flex-wrap" style={{ color: colors.textMuted }}>
                  {event.status === 'started' ? (
                    <span className="animate-pulse" style={{ color: '#3b82f6' }}>running…</span>
                  ) : (
                    <span style={event.status === 'error' ? { color: '#ef4444' } : undefined}>
                      {event.status === 'error' ? 'failed' : '✓'}
                      {event.duration_ms != null && ` ${formatDuration(event.duration_ms)}`}
                    </span>
                  )}
                  {event.at && <span>{new Date(event.at).toLocaleTimeString()}</span>}
                </div>
              </div>
              {expandable && <Chevron open={isExpanded} color={colors.textMuted} />}
            </div>

            {isExpanded && (
              <div className="ml-3 mt-1 mb-2 pl-4 space-y-2 border-l-2" style={{ borderColor: bubble.color + '55' }}>
                {event.input && (
                  <div>
                    <div className="text-xs uppercase tracking-wide mb-1" style={{ color: colors.textMuted }}>Input</div>
                    <pre style={{ ...preStyle, whiteSpace: 'pre-wrap', maxHeight: '160px', overflowY: 'auto' }}>{prettyEventJson(event.input)}</pre>
                  </div>
                )}
                {event.output && (
                  <div>
                    <div className="text-xs uppercase tracking-wide mb-1" style={{ color: colors.textMuted }}>
                      {event.status === 'error' ? 'Error' : 'Result'}
                    </div>
                    <pre
                      style={{
                        ...preStyle,
                        whiteSpace: 'pre-wrap',
                        maxHeight: '224px',
                        overflowY: 'auto',
                        ...(event.status === 'error' ? { background: darkMode ? 'rgba(239,68,68,0.12)' : '#fef2f2', color: darkMode ? '#fca5a5' : '#b91c1c' } : {}),
                      }}
                    >{prettyEventJson(event.output)}</pre>
                  </div>
                )}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// Status pill + the run's vitals, shown under the feed while a run is in
// flight and after it settles.
function RunVitals({ run, darkMode, colors }) {
  if (!run) return null;
  return (
    <div className="flex items-center gap-3 flex-wrap text-xs" style={{ color: colors.textMuted }}>
      <span data-testid="runner-status" style={{ display: 'inline-flex' }}>
        <Badge tone={STATUS_TONE[run.status] || 'neutral'} darkMode={darkMode}>{run.status}</Badge>
      </span>
      {run.output_metadata?.model && (
        <span className="font-mono" title="Model that generated this run">
          {run.output_metadata.provider}/{run.output_metadata.model}
        </span>
      )}
      {run.duration_ms ? <span>{formatDuration(run.duration_ms)}</span> : null}
      {run.total_tokens ? <span>{run.total_tokens} tokens</span> : null}
      {run.trace_id && (
        <a
          href={dashboardPath(`/traces?trace=${run.trace_id}`)}
          className="font-mono hover:underline"
          style={{ color: colors.textSecondary }}
          title={`${run.trace_id} — open in Traces`}
        >
          trace:{run.trace_id.slice(0, 8)} →
        </a>
      )}
    </div>
  );
}

export default function AgentRunner({ agent, onBack }) {
  const { darkMode } = useTheme();
  const colors = paletteFor(darkMode);

  // Named action to invoke; agents always have the default #ask, plus any
  // configured action prompts (Instructions tab).
  const actionPrompts = agent.action_prompts || agent.actionPrompts || [];
  const actionNames = ['ask', ...actionPrompts.map((ap) => ap.name).filter(Boolean)];
  const [actionName, setActionName] = useState('ask');

  const [prompt, setPrompt] = useState('');
  // Files waiting in the composer: the File itself plus the chip fields the
  // persisted manifest will have, so the chip is the same before and after.
  const [pendingFiles, setPendingFiles] = useState([]);
  const [dragOver, setDragOver] = useState(false);

  const [conversations, setConversations] = useState([]);
  const [conversationId, setConversationId] = useState(null);
  const [conversation, setConversation] = useState(null);
  const [conversationError, setConversationError] = useState(null);

  const [runs, setRuns] = useState([]);
  const [isRunning, setIsRunning] = useState(false);
  const [currentRun, setCurrentRun] = useState(null);
  // The user turn just sent, shown until the reloaded conversation has it.
  const [pendingTurn, setPendingTurn] = useState(null);
  // A Recent Runs row with no conversation to jump to: its output, inline.
  const [inspectedRun, setInspectedRun] = useState(null);
  const [runError, setRunError] = useState(null);
  const [expandedEvents, setExpandedEvents] = useState({});

  const [limitUsage, setLimitUsage] = useState(null);
  const [isUpgrading, setIsUpgrading] = useState(false);
  const [upgradeError, setUpgradeError] = useState(null);

  const [systemOpen, setSystemOpen] = useState(false);
  const [addMenuOpen, setAddMenuOpen] = useState(false);
  const [inlineRole, setInlineRole] = useState(null);
  const [inlineDraft, setInlineDraft] = useState('');
  const [inlineBusy, setInlineBusy] = useState(false);
  const [inlineError, setInlineError] = useState(null);

  // A conversation picked on purpose (picker, New conversation, a Recent
  // Runs row) survives a list refresh; otherwise the newest one is shown.
  const pinnedRef = useRef(null);
  const conversationIdRef = useRef(null);
  // Bumped to abandon a poll loop when the run it belongs to is superseded
  // or the page unmounts.
  const pollTokenRef = useRef(0);
  // False once the page is gone, so a request still in flight cannot start a
  // poll loop the unmount has no way left to stop.
  const mountedRef = useRef(true);
  // Mirrors of the two states that hold object URLs, so the code that
  // revokes them reads the current value outside a render.
  const pendingTurnRef = useRef(null);
  const pendingFilesRef = useRef([]);
  const contextRef = useRef(null);
  const messagesRef = useRef(null);
  const fileInputRef = useRef(null);
  const addMenuRef = useRef(null);

  const visibleMessages = (conversation?.messages || []).filter((message) => CONVERSATION_ROLES.includes(message.role));

  useEffect(() => { pendingTurnRef.current = pendingTurn; }, [pendingTurn]);
  useEffect(() => { pendingFilesRef.current = pendingFiles; }, [pendingFiles]);

  useEffect(() => {
    mountedRef.current = true;
    loadRuns();
    return () => {
      mountedRef.current = false;
      pollTokenRef.current += 1;
      // Thumbnails still in the composer or the in-flight turn hold object
      // URLs the browser only frees on revoke.
      releaseTurn(pendingTurnRef.current);
      releaseTurn({ attachments: pendingFilesRef.current });
      setPendingTurn(null);
      setPendingFiles([]);
    };
  }, [agent.id]);

  useEffect(() => {
    loadConversations(actionName);
  }, [agent.id, actionName]);

  useEffect(() => {
    conversationIdRef.current = conversationId;
    if (conversationId) {
      loadConversation(conversationId);
    } else {
      setConversation(null);
      setConversationError(null);
    }
  }, [conversationId]);

  // Keep the newest turn in view as messages, feed events and composers land.
  useEffect(() => {
    const node = messagesRef.current;
    if (node) node.scrollTop = node.scrollHeight;
  }, [visibleMessages.length, pendingTurn, currentRun?.logs?.length, inlineRole, inspectedRun]);

  useEffect(() => {
    if (!addMenuOpen) return undefined;
    const close = (event) => {
      if (addMenuRef.current && !addMenuRef.current.contains(event.target)) setAddMenuOpen(false);
    };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [addMenuOpen]);

  const loadRuns = async () => {
    try {
      const response = await fetch(`/api/agents/${agent.id}/runs?per_page=10`);
      const data = await response.json();
      setRuns(data.runs || []);
    } catch (error) {
      console.error('Failed to load runs:', error);
    }
  };

  const loadConversations = async (action) => {
    try {
      const response = await fetch(`/api/agents/${agent.id}/conversations?action_name=${encodeURIComponent(action)}`);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      const list = data.conversations || [];
      setConversations(list);
      setConversationId((current) => {
        if (current && (pinnedRef.current === current || list.some((item) => item.id === current))) return current;
        return list[0]?.id ?? null;
      });
    } catch (error) {
      console.error('Failed to load conversations:', error);
      setConversations([]);
    }
  };

  const loadConversation = async (id) => {
    try {
      const response = await fetch(`/api/interactions/${id}`);
      if (!response.ok) throw new Error(response.status === 404 ? 'Conversation not found' : `HTTP ${response.status}`);
      const data = await response.json();
      // A slower response for a conversation we have since left is stale.
      if (conversationIdRef.current !== id) return;
      setConversation(data.interaction);
      setConversationError(null);
    } catch (error) {
      if (conversationIdRef.current !== id) return;
      setConversation(null);
      setConversationError(error.message);
    }
  };

  const createConversation = async () => {
    const response = await fetch(`/api/agents/${agent.id}/conversations`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action_name: actionName }),
    });
    const data = await parseJson(response);
    if (!response.ok || !data.conversation) throw new Error(data.error || `Could not start a conversation (HTTP ${response.status})`);
    const created = data.conversation;
    setConversations((prev) => [created, ...prev.filter((item) => item.id !== created.id)]);
    pinnedRef.current = created.id;
    setConversationId(created.id);
    return created.id;
  };

  // The conversation a run or a seeded message lands in — the pinned one,
  // else a fresh one, so even the very first message has a home.
  const ensureConversation = () => (conversationIdRef.current ? Promise.resolve(conversationIdRef.current) : createConversation());

  const changeAction = (name) => {
    pinnedRef.current = null;
    setActionName(name);
  };

  // The run panel belongs to the conversation on screen: its status pill,
  // activity feed and failure box would otherwise describe the last run of a
  // conversation the user has navigated away from.
  const clearRunPanel = () => {
    setCurrentRun(null);
    setRunError(null);
    setExpandedEvents({});
  };

  const pickConversation = (value) => {
    const id = value ? Number(value) : null;
    if (id !== conversationIdRef.current) clearRunPanel();
    pinnedRef.current = id;
    setConversationId(id);
    setInspectedRun(null);
  };

  const handleNewConversation = async () => {
    if (isRunning) return;
    try {
      await createConversation();
      setConversationError(null);
      setInspectedRun(null);
      clearRunPanel();
      releaseTurn(pendingTurnRef.current);
      setPendingTurn(null);
      setInlineRole(null);
    } catch (error) {
      setConversationError(error.message);
    }
  };

  const releaseTurn = (turn) => {
    (turn?.attachments || []).forEach((attachment) => {
      if (attachment.url && attachment.url.startsWith('blob:')) URL.revokeObjectURL(attachment.url);
    });
  };

  const addFiles = (fileList) => {
    const incoming = Array.from(fileList || []).filter(Boolean);
    if (incoming.length === 0) return;
    setPendingFiles((prev) => [
      ...prev,
      ...incoming.map((file) => ({
        file,
        filename: file.name,
        content_type: file.type || 'application/octet-stream',
        byte_size: file.size,
        kind: attachmentKind(file),
        url: file.type && file.type.startsWith('image/') ? URL.createObjectURL(file) : null,
      })),
    ]);
  };

  const removeFile = (index) => {
    setPendingFiles((prev) => {
      const target = prev[index];
      if (target?.url) URL.revokeObjectURL(target.url);
      return prev.filter((_, i) => i !== index);
    });
  };

  const finishRun = (run, contextId) => {
    setIsRunning(false);
    releaseTurn(pendingTurnRef.current);
    setPendingTurn(null);
    loadRuns();
    const usedContext = contextIdOf(run) ?? contextId;
    if (!usedContext) return;
    if (usedContext !== conversationIdRef.current) {
      // The service settled on another context (the pinned one was not this
      // agent's, say): follow it so the reply is on screen.
      pinnedRef.current = usedContext;
      setConversationId(usedContext);
    } else {
      loadConversation(usedContext);
    }
    loadConversations(actionName);
  };

  // Poll the run endpoint so the activity feed streams pending llm/tool/agent
  // events while the run executes; reload the conversation once it settles.
  const pollRun = (runId, contextId) => {
    // Claiming a token after the unmount cleanup already bumped it would
    // re-arm the loop against a tree that is gone.
    if (!mountedRef.current) return;
    const token = ++pollTokenRef.current;
    const startedPolling = Date.now();
    const poll = async () => {
      if (pollTokenRef.current !== token) return;
      try {
        const runResponse = await fetch(`/api/runs/${runId}`);
        if (runResponse.ok) {
          const runData = await runResponse.json();
          if (pollTokenRef.current !== token) return;
          setCurrentRun(runData.run);
          if (!['pending', 'running'].includes(runData.run.status)) {
            finishRun(runData.run, contextId);
            return;
          }
        }
      } catch {
        // transient poll failure — keep trying until timeout
      }
      if (Date.now() - startedPolling < POLL_TIMEOUT_MS) {
        setTimeout(poll, POLL_INTERVAL_MS);
      } else {
        // Same teardown as a finished run, minus the reload: the turn stops
        // showing as in flight and its thumbnails give their URLs back.
        setIsRunning(false);
        releaseTurn(pendingTurnRef.current);
        setPendingTurn(null);
        setCurrentRun((prev) => (prev ? { ...prev, status: 'failed', error_message: 'Timed out waiting for the run to finish.' } : prev));
        setRunError('Timed out waiting for the run to finish.');
      }
    };
    poll();
  };

  // Kick off an async run: the prompt and files go up as multipart form data
  // together with the pinned conversation, then the run is polled.
  const startRun = async ({ text, files, fromComposer = false }) => {
    const trimmed = (text || '').trim();
    if ((!trimmed && files.length === 0) || isRunning) return;

    setRunError(null);
    setInspectedRun(null);
    setInlineRole(null);
    setIsRunning(true);
    setExpandedEvents({});
    setCurrentRun({ status: 'pending', input_prompt: trimmed, output: '', logs: [], started_at: new Date().toISOString() });
    releaseTurn(pendingTurnRef.current);
    setPendingTurn({ content: trimmed || '(see attached files)', attachments: files.map(({ file, ...chip }) => chip) });
    // Only a run the composer sent empties it: a form submission or a choice
    // click would otherwise throw away a draft and its staged files, which
    // are not part of that run and are never uploaded.
    if (fromComposer) {
      setPrompt('');
      setPendingFiles([]);
    }

    let contextId = conversationIdRef.current;
    if (!contextId) {
      try {
        contextId = await createConversation();
      } catch (error) {
        setRunError(`${error.message} — running without a pinned conversation.`);
      }
    }

    const restoreComposer = () => {
      if (fromComposer) {
        setPrompt(trimmed);
        setPendingFiles(files);
      }
      setPendingTurn(null);
    };

    try {
      const body = new FormData();
      body.append('prompt', trimmed);
      body.append('action_name', actionName);
      if (contextId) body.append('params[context_id]', String(contextId));
      files.forEach(({ file }) => body.append('attachments[]', file, file.name));

      const response = await fetch(`/api/agents/${agent.id}/execute`, { method: 'POST', body });
      const data = await parseJson(response);

      // Plan limit reached (402) — show the upgrade prompt
      if (response.status === 402 && data.upgrade_required) {
        setLimitUsage(data.usage);
        setCurrentRun((prev) => ({ ...prev, status: 'failed', error_message: data.message || 'Plan limit reached' }));
        setIsRunning(false);
        restoreComposer();
        return;
      }

      if (!response.ok) {
        throw new Error(data.error || 'Run failed');
      }

      pollRun(data.run.id, contextIdOf(data.run) ?? contextId);
    } catch (error) {
      setCurrentRun((prev) => ({ ...prev, status: 'failed', error_message: error.message }));
      setIsRunning(false);
      restoreComposer();
    }
  };

  const handleRun = () => startRun({ text: prompt, files: pendingFiles, fromComposer: true });

  // A submitted form or clicked choice in the assistant's UI is the next
  // user message.
  const handleUiAction = (action) => {
    if (!action || !action.text) return;
    startRun({ text: action.text, files: [] });
  };

  const handleKeyDown = (event) => {
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      handleRun();
    }
  };

  const editMessage = async (message, content) => {
    const contextId = conversationIdRef.current;
    const response = await fetch(`/api/interactions/${contextId}/messages/${message.id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content }),
    });
    const data = await parseJson(response);
    if (!response.ok) throw new Error(data.error || `Could not save the message (HTTP ${response.status})`);
    await loadConversation(contextId);
  };

  const deleteMessage = async (message) => {
    const contextId = conversationIdRef.current;
    try {
      const response = await fetch(`/api/interactions/${contextId}/messages/${message.id}`, { method: 'DELETE' });
      if (!response.ok) {
        const data = await parseJson(response);
        throw new Error(data.error || `Could not delete the message (HTTP ${response.status})`);
      }
      setConversationError(null);
      await loadConversation(contextId);
      loadConversations(actionName);
    } catch (error) {
      setConversationError(error.message);
    }
  };

  const openInlineComposer = (role) => {
    setAddMenuOpen(false);
    setInlineRole(role);
    setInlineDraft('');
    setInlineError(null);
  };

  // Seeds history without a run: the message is persisted to the context so
  // the next run sends it to the model as if it had happened.
  const addInlineMessage = async () => {
    const content = inlineDraft.trim();
    if (!content || inlineBusy) return;
    setInlineBusy(true);
    setInlineError(null);
    try {
      const contextId = await ensureConversation();
      const response = await fetch(`/api/interactions/${contextId}/messages`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ role: inlineRole, content }),
      });
      const data = await parseJson(response);
      if (!response.ok) throw new Error(data.error || `Could not add the message (HTTP ${response.status})`);
      setInlineDraft('');
      setInlineRole(null);
      await loadConversation(contextId);
      loadConversations(actionName);
    } catch (error) {
      setInlineError(error.message);
    } finally {
      setInlineBusy(false);
    }
  };

  // A Recent Runs row opens the conversation the run belongs to; a run with
  // no conversation (single-turn, older data) shows its output inline. The
  // list rows are summaries, so the detail is fetched when they lack the
  // context and output fields.
  const openRun = async (run) => {
    let detail = run;
    if (contextIdOf(run) == null) {
      try {
        const response = await fetch(`/api/runs/${run.id}`);
        if (response.ok) detail = (await response.json()).run;
      } catch (error) {
        console.error('Failed to load run details:', error);
      }
    }
    const contextId = contextIdOf(detail);
    if (contextId) {
      setInspectedRun(null);
      if (contextId !== conversationIdRef.current) clearRunPanel();
      pinnedRef.current = contextId;
      const runAction = detail.action_name || run.action_name;
      if (runAction && actionNames.includes(runAction) && runAction !== actionName) setActionName(runAction);
      setConversationId(contextId);
    } else {
      setInspectedRun({
        ...detail,
        output: detail.output ?? detail.output_preview,
        error_message: detail.error_message ?? detail.error,
      });
    }
    contextRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  const handleUpgrade = async () => {
    setIsUpgrading(true);
    setUpgradeError(null);
    try {
      await startCheckout({ planSlug: 'pro' });
    } catch (err) {
      setUpgradeError(err.message);
      setIsUpgrading(false);
    }
  };

  const upgradeUrl = window.ACTIVE_AGENT_DASHBOARD?.meta?.upgradeUrl;

  // The system prompt the selected action runs under: base instructions
  // with the action's prompt stacked below (Agent#composed_instructions_for).
  const actionPrompt = actionPrompts.find((ap) => ap.name === actionName)?.prompt;
  const composedInstructions = [agent.instructions, actionName === 'ask' ? null : actionPrompt]
    .map((part) => (part || '').trim())
    .filter(Boolean)
    .join('\n\n') || conversation?.instructions || '';

  const conversationOptions = conversations.slice();
  if (conversationId && !conversationOptions.some((item) => item.id === conversationId)) {
    // Pinned from a run of another action: keep it selectable.
    conversationOptions.unshift({ id: conversationId, message_count: visibleMessages.length });
  }

  const canRun = (prompt.trim().length > 0 || pendingFiles.length > 0) && !isRunning;
  const runFailed = currentRun && !isRunning && currentRun.status === 'failed';
  // A finished run whose reply has nowhere to show: no conversation to reload.
  const runOutputInline = currentRun && !isRunning && currentRun.status === 'complete' && !contextIdOf(currentRun) && !conversationId;

  const card = { background: colors.cardBg, border: `1px solid ${colors.cardBorder}`, borderRadius: '12px' };
  const divider = { borderBottom: `1px solid ${colors.cardBorder}` };
  const selectStyle = {
    padding: '6px 10px',
    borderRadius: '8px',
    border: `1px solid ${colors.inputBorder}`,
    background: colors.inputBg,
    color: colors.textPrimary,
    fontSize: '13px',
    fontFamily: TYPOGRAPHY.mono,
    maxWidth: '260px',
  };
  const fieldStyle = {
    width: '100%',
    padding: '10px 12px',
    borderRadius: '8px',
    border: `1px solid ${dragOver ? ACCENT : colors.inputBorder}`,
    background: colors.inputBg,
    color: colors.textPrimary,
    fontFamily: 'inherit',
    fontSize: '13px',
    resize: 'vertical',
  };
  const systemBubble = roleBubble('system', darkMode);
  const preStyle = streamPreStyle(darkMode);

  return (
    <div className="grid grid-cols-3 gap-6 h-full">
      {/* Workbench */}
      <div className="col-span-2 flex flex-col gap-4 min-w-0">
        {/* Plan limit banner */}
        {limitUsage && (
          <div className="bg-amber-50 border border-amber-200 rounded-xl p-4 flex items-center justify-between gap-4">
            <div>
              <p className="font-medium text-amber-900">Monthly run limit reached</p>
              <p className="text-sm text-amber-700 mt-0.5">
                You've used {limitUsage.runs_used} of {limitUsage.runs_limit} runs on the{' '}
                {limitUsage.plan || 'free'} plan. Upgrade to keep running agents.
              </p>
              {upgradeError && <p className="text-sm text-red-600 mt-1">{upgradeError}</p>}
            </div>
            <div className="flex items-center gap-2 flex-shrink-0">
              {/* Same source as startCheckout: the host's upgrade_url, or
                  nothing — the engine has no /pricing of its own. */}
              {upgradeUrl && (
                <a href={upgradeUrl} className="px-4 py-2 text-sm text-amber-800 hover:text-amber-900">
                  See plans
                </a>
              )}
              <button
                onClick={handleUpgrade}
                disabled={isUpgrading}
                className="px-4 py-2 text-sm bg-amber-500 text-white rounded-lg hover:bg-amber-600 transition-colors disabled:opacity-50"
              >
                {isUpgrading ? 'Redirecting…' : 'Upgrade to Pro'}
              </button>
            </div>
          </div>
        )}

        {/* Toolbar: who is being tested, which action, which conversation. */}
        <div data-testid="runner-toolbar" style={card} className="p-4 flex items-center gap-3 flex-wrap">
          <AgentAvatar size={40} />
          <div className="min-w-0">
            <div className="font-semibold truncate" style={{ color: colors.textPrimary }}>{agent.name}</div>
            <div className="text-xs font-mono" style={{ color: colors.textSecondary }}>{agent.provider} / {agent.model}</div>
          </div>
          <div className="flex items-center gap-2 flex-wrap ml-auto">
            <select
              data-testid="runner-action-select"
              value={actionName}
              onChange={(event) => changeAction(event.target.value)}
              disabled={isRunning}
              className="aa-field"
              style={selectStyle}
              title="Agent action to invoke"
            >
              {actionNames.map((name) => (
                <option key={name} value={name}>#{name}</option>
              ))}
            </select>
            <select
              data-testid="runner-conversation-select"
              value={conversationId ?? ''}
              onChange={(event) => pickConversation(event.target.value)}
              disabled={isRunning}
              className="aa-field"
              style={selectStyle}
              title="Conversation to continue"
            >
              <option value="">New conversation on first run</option>
              {conversationOptions.map((item) => (
                <option key={item.id} value={item.id}>
                  Conversation #{item.id} · {item.message_count ?? 0} message{item.message_count === 1 ? '' : 's'}
                </option>
              ))}
            </select>
            <Button testId="runner-new-conversation" variant="secondary" size="sm" colors={colors} onClick={handleNewConversation} disabled={isRunning} title="Start an empty conversation for this action">
              + New conversation
            </Button>
            <Button testId="runner-back" variant="secondary" size="sm" colors={colors} onClick={onBack}>
              ← Back to editor
            </Button>
          </div>
        </div>

        {/* Context: the conversation as the model will see it. */}
        <div data-testid="runner-context" ref={contextRef} style={card} className="flex flex-col overflow-hidden">
          <div className="px-4 py-3 flex items-center justify-between gap-3 flex-wrap" style={divider}>
            <div className="flex items-center gap-2 min-w-0">
              <h3 className="font-medium" style={{ color: colors.textPrimary }}>Context</h3>
              {conversation && (
                <span className="text-xs font-mono" style={{ color: colors.textMuted }}>
                  #{conversation.id} · {visibleMessages.length} message{visibleMessages.length === 1 ? '' : 's'}
                </span>
              )}
            </div>
            <div className="flex items-center gap-3 flex-wrap">
              <RunVitals run={currentRun} darkMode={darkMode} colors={colors} />
              <div className="relative" ref={addMenuRef}>
                <Button testId="runner-add-message" variant="secondary" size="sm" colors={colors} onClick={() => setAddMenuOpen((open) => !open)} disabled={isRunning} title="Insert a message into the context without running">
                  + Add message
                </Button>
                {addMenuOpen && (
                  <div
                    className="absolute right-0 mt-1 z-10 py-1 rounded-lg shadow-lg"
                    style={{ background: colors.cardBg, border: `1px solid ${colors.borderStrong}`, minWidth: '180px' }}
                  >
                    {[['user', 'runner-add-user-message', 'User message'], ['assistant', 'runner-add-assistant-message', 'Assistant message']].map(([role, id, label]) => (
                      <button
                        key={role}
                        type="button"
                        data-testid={id}
                        onClick={() => openInlineComposer(role)}
                        className="w-full text-left px-3 py-1.5 text-sm hover:bg-black/5"
                        style={{ color: colors.textCell, background: 'none', border: 'none', cursor: 'pointer' }}
                      >
                        {label}
                      </button>
                    ))}
                  </div>
                )}
              </div>
            </div>
          </div>

          <div ref={messagesRef} className="p-4 overflow-auto" style={{ maxHeight: '60vh' }}>
            {/* System row — the composed instructions, read-only here. */}
            <div
              data-testid="runner-system-row"
              className="flex gap-3 items-start rounded-lg -mx-2 px-2 py-1 cursor-pointer"
              onClick={() => setSystemOpen((open) => !open)}
              title={systemOpen ? 'Collapse system instructions' : 'Show system instructions'}
            >
              <span className="flex flex-col gap-1 flex-shrink-0 mt-0.5" style={{ minWidth: '72px' }}>
                <span className="px-2 py-0.5 rounded text-xs font-medium" style={{ background: systemBubble.background, color: systemBubble.color, textAlign: 'center' }}>
                  {systemBubble.label}
                </span>
              </span>
              <div className="min-w-0 flex-1">
                {composedInstructions ? (
                  systemOpen ? (
                    <pre style={{ ...preStyle, whiteSpace: 'pre-wrap', maxHeight: '260px', overflowY: 'auto' }}>{composedInstructions}</pre>
                  ) : (
                    <div className="text-sm truncate" style={{ color: colors.textSecondary }}>
                      {composedInstructions.split('\n').find((line) => line.trim()) || ''}
                    </div>
                  )
                ) : (
                  <div className="text-sm" style={{ color: colors.textMuted }}>No system instructions</div>
                )}
                <div className="text-xs mt-0.5 font-mono" style={{ color: colors.textMuted }}>
                  read-only · Edit in the Instructions tab
                </div>
              </div>
              <Chevron open={systemOpen} color={colors.textMuted} />
            </div>

            {conversationError && (
              <div className="text-sm mt-3" style={{ color: '#dc2626' }}>{conversationError}</div>
            )}

            {visibleMessages.length > 0 ? (
              <div className="mt-3">
                <InteractionStream
                  messages={visibleMessages}
                  darkMode={darkMode}
                  testIdPrefix="runner-message"
                  onUiAction={handleUiAction}
                  onEditMessage={editMessage}
                  onDeleteMessage={deleteMessage}
                />
              </div>
            ) : (
              !pendingTurn && !inspectedRun && !runFailed && (
                <div data-testid="runner-context-empty" className="text-sm text-center py-8" style={{ color: colors.textMuted }}>
                  No messages yet — say something below to test the agent as a user.
                </div>
              )
            )}

            {pendingTurn && (
              <div data-testid="runner-pending-turn" className="flex gap-3 items-start rounded-lg -mx-2 px-2 py-1 mt-3">
                <span className="flex flex-col gap-1 flex-shrink-0 mt-0.5" style={{ minWidth: '72px' }}>
                  <span className="px-2 py-0.5 rounded text-xs font-medium" style={{ background: roleBubble('user', darkMode).background, color: roleBubble('user', darkMode).color, textAlign: 'center' }}>
                    User
                  </span>
                </span>
                <div className="min-w-0 flex-1">
                  <div className="text-sm break-words whitespace-pre-wrap" style={{ color: colors.textPrimary }}>{pendingTurn.content}</div>
                  <AttachmentChips attachments={pendingTurn.attachments} darkMode={darkMode} />
                </div>
              </div>
            )}

            {currentRun && (isRunning || activityFeed(currentRun).length > 0) && (
              <div className="mt-3 space-y-2">
                <ActivityFeed
                  run={currentRun}
                  darkMode={darkMode}
                  colors={colors}
                  expanded={expandedEvents}
                  onToggle={(eid) => setExpandedEvents((prev) => ({ ...prev, [eid]: !prev[eid] }))}
                />
                {isRunning && (
                  <div className="flex items-center gap-2 text-sm" style={{ color: colors.textSecondary }}>
                    <span className="animate-pulse">●</span>
                    <span>{activityFeed(currentRun).length > 0 ? 'Working…' : 'Starting run…'}</span>
                  </div>
                )}
              </div>
            )}

            {runError && (
              <div className="text-xs mt-3" style={{ color: '#d97706' }}>{runError}</div>
            )}

            {runFailed && currentRun.error_message && (
              <div className="mt-3 rounded-lg p-3 text-sm" style={{ background: darkMode ? 'rgba(239,68,68,0.12)' : '#fef2f2', color: darkMode ? '#fca5a5' : '#b91c1c' }}>
                <div className="font-semibold mb-1">Run failed</div>
                <pre className="whitespace-pre-wrap font-mono text-xs" style={{ margin: 0 }}>{currentRun.error_message}</pre>
              </div>
            )}

            {runOutputInline && (
              <div className="mt-3 rounded-lg p-3 text-sm" style={{ background: colors.innerBg, color: colors.textPrimary }}>
                <div className="text-xs uppercase tracking-wide mb-1" style={{ color: colors.textMuted }}>Output</div>
                <Markdown text={currentRun.output || 'No output'} darkMode={darkMode} onUiAction={handleUiAction} />
              </div>
            )}

            {inspectedRun && (
              <div data-testid="runner-inspected-run" className="mt-3 rounded-lg p-3" style={{ background: colors.innerBg, border: `1px solid ${colors.cardBorder}` }}>
                <div className="flex items-center justify-between gap-3 flex-wrap mb-2">
                  <div className="flex items-center gap-2 text-xs font-mono" style={{ color: colors.textMuted }}>
                    <span style={{ color: colors.textPrimary }}>Run #{inspectedRun.id}</span>
                    <Badge tone={STATUS_TONE[inspectedRun.status] || 'neutral'} darkMode={darkMode}>{inspectedRun.status}</Badge>
                    {inspectedRun.output_metadata?.model && <span>{inspectedRun.output_metadata.provider}/{inspectedRun.output_metadata.model}</span>}
                    {inspectedRun.duration_ms ? <span>{formatDuration(inspectedRun.duration_ms)}</span> : null}
                    {inspectedRun.trace_id && (
                      <a href={dashboardPath(`/traces?trace=${inspectedRun.trace_id}`)} className="hover:underline" style={{ color: colors.textSecondary }}>
                        trace:{inspectedRun.trace_id.slice(0, 8)} →
                      </a>
                    )}
                    <span>· no conversation attached</span>
                  </div>
                  <button
                    type="button"
                    onClick={() => setInspectedRun(null)}
                    className="text-xs font-mono"
                    style={{ color: colors.textMuted, background: 'none', border: 'none', cursor: 'pointer' }}
                    title="Close"
                  >
                    [x]
                  </button>
                </div>
                {(inspectedRun.input_prompt || inspectedRun.input_preview) && (
                  <div className="text-sm mb-2 whitespace-pre-wrap" style={{ color: colors.textSecondary }}>
                    {inspectedRun.input_prompt || inspectedRun.input_preview}
                  </div>
                )}
                {inspectedRun.error_message ? (
                  <pre className="whitespace-pre-wrap font-mono text-xs" style={{ margin: 0, color: darkMode ? '#fca5a5' : '#b91c1c' }}>{inspectedRun.error_message}</pre>
                ) : (
                  <div className="text-sm" style={{ color: colors.textPrimary }}>
                    <Markdown text={inspectedRun.output || 'No output'} darkMode={darkMode} />
                  </div>
                )}
              </div>
            )}

            {inlineRole && (
              <div className="mt-3 rounded-lg p-3" style={{ border: `1px dashed ${colors.borderStrong}` }}>
                <div className="flex items-center gap-2 mb-2">
                  <span className="px-2 py-0.5 rounded text-xs font-medium" style={{ background: roleBubble(inlineRole, darkMode).background, color: roleBubble(inlineRole, darkMode).color }}>
                    {roleBubble(inlineRole, darkMode).label}
                  </span>
                  <span className="text-xs" style={{ color: colors.textMuted }}>Added to the context without running the agent</span>
                </div>
                <textarea
                  data-testid="runner-inline-composer"
                  value={inlineDraft}
                  onChange={(event) => setInlineDraft(event.target.value)}
                  onKeyDown={(event) => {
                    if (event.key === 'Escape') setInlineRole(null);
                    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) addInlineMessage();
                  }}
                  placeholder={inlineRole === 'user' ? 'What the user said…' : 'What the assistant replied…'}
                  rows={3}
                  autoFocus
                  className="aa-field"
                  style={{ ...fieldStyle, border: `1px solid ${colors.inputBorder}` }}
                />
                <div className="flex items-center gap-2 mt-2 flex-wrap">
                  <Button testId="runner-inline-submit" variant="primary" size="sm" colors={colors} onClick={addInlineMessage} disabled={inlineBusy || !inlineDraft.trim()}>
                    {inlineBusy ? 'Adding…' : `Add ${inlineRole} message`}
                  </Button>
                  <Button variant="secondary" size="sm" colors={colors} onClick={() => setInlineRole(null)} disabled={inlineBusy}>
                    Cancel
                  </Button>
                  {inlineError && <span className="text-xs" style={{ color: '#dc2626' }}>{inlineError}</span>}
                </div>
              </div>
            )}
          </div>
        </div>

        {/* Composer */}
        <div style={card} className="p-4">
          <div
            onDragOver={(event) => {
              event.preventDefault();
              if (!dragOver) setDragOver(true);
            }}
            onDragLeave={() => setDragOver(false)}
            onDrop={(event) => {
              event.preventDefault();
              setDragOver(false);
              if (!isRunning) addFiles(event.dataTransfer?.files);
            }}
          >
            <textarea
              data-testid="runner-prompt"
              value={prompt}
              onChange={(event) => setPrompt(event.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Message the agent as a user… (⌘/Ctrl+Enter to run · drop files here to attach)"
              rows={3}
              disabled={isRunning}
              className="aa-field"
              style={fieldStyle}
            />
          </div>
          <AttachmentChips
            attachments={pendingFiles}
            darkMode={darkMode}
            testId="runner-attachment-chip"
            onRemove={(_, index) => removeFile(index)}
            removeTestId="runner-attachment-remove"
          />
          <div className="flex items-center justify-between gap-3 flex-wrap mt-3">
            <div className="flex items-center gap-3 flex-wrap">
              <input
                ref={fileInputRef}
                data-testid="runner-attach-input"
                type="file"
                multiple
                style={{ display: 'none' }}
                onChange={(event) => {
                  addFiles(event.target.files);
                  event.target.value = '';
                }}
              />
              <Button testId="runner-attach" variant="secondary" size="sm" colors={colors} onClick={() => fileInputRef.current?.click()} disabled={isRunning} title="Attach images, PDFs, or text files to this message">
                📎 Attach files
              </Button>
              <span className="text-xs" style={{ color: colors.textMuted }}>
                Press <kbd className="px-1.5 py-0.5 rounded" style={{ background: colors.mutedBg, color: colors.textSecondary }}>⌘</kbd> + <kbd className="px-1.5 py-0.5 rounded" style={{ background: colors.mutedBg, color: colors.textSecondary }}>Enter</kbd> to run
              </span>
            </div>
            <Button testId="runner-run" variant="primary" colors={colors} onClick={handleRun} disabled={!canRun}>
              {isRunning ? (
                <>
                  <span className="animate-spin inline-block" style={{ fontFamily: TYPOGRAPHY.mono }}>{'[~]'}</span> Running…
                </>
              ) : (
                <>
                  <span style={{ fontFamily: TYPOGRAPHY.mono }}>{'[>]'}</span> Run
                </>
              )}
            </Button>
          </div>
        </div>
      </div>

      {/* Sidebar */}
      <div className="space-y-4 min-w-0">
        {/* Configuration Preview */}
        <div style={card} className="p-4">
          <h4 className="font-medium mb-3" style={{ color: colors.textPrimary }}>Configuration</h4>
          <dl className="space-y-2 text-sm">
            <div className="flex justify-between">
              <dt style={{ color: colors.textSecondary }}>Temperature</dt>
              <dd style={{ color: colors.textPrimary }}>{agent.modelConfig?.temperature || agent.model_config?.temperature || 0.7}</dd>
            </div>
            <div className="flex justify-between">
              <dt style={{ color: colors.textSecondary }}>Tools</dt>
              <dd style={{ color: colors.textPrimary }}>{agent.tools?.length || 0}</dd>
            </div>
            <div className="flex justify-between items-center">
              <dt style={{ color: colors.textSecondary }}>Status</dt>
              <dd><Badge tone={agent.status === 'active' ? 'success' : 'neutral'} darkMode={darkMode}>{agent.status}</Badge></dd>
            </div>
          </dl>

          {agent.instructions && (
            <div className="mt-3 pt-3" style={{ borderTop: `1px solid ${colors.cardBorder}` }}>
              <div className="text-xs mb-1.5" style={{ color: colors.textSecondary }}>System Instructions</div>
              <p className="text-xs whitespace-pre-wrap max-h-44 overflow-y-auto font-mono leading-relaxed" style={{ color: colors.textCell }}>
                {agent.instructions}
              </p>
            </div>
          )}
        </div>

        {/* Recent Runs */}
        <div style={card} className="overflow-hidden">
          <div className="px-4 py-3" style={divider}>
            <h4 className="font-medium" style={{ color: colors.textPrimary }}>Recent Runs</h4>
          </div>

          <div className="max-h-64 overflow-auto">
            {runs.length > 0 ? (
              <div>
                {runs.map((run) => (
                  <div
                    key={run.id}
                    data-testid="runner-recent-run"
                    className="px-4 py-3 cursor-pointer hover:bg-black/5"
                    style={{ borderBottom: `1px solid ${colors.cardBorder}` }}
                    onClick={() => openRun(run)}
                    title={contextIdOf(run) ? 'Open this run’s conversation' : 'Show this run’s output'}
                  >
                    <div className="flex items-center justify-between mb-1">
                      <Badge tone={STATUS_TONE[run.status] || 'neutral'} darkMode={darkMode}>{run.status}</Badge>
                      <span className="text-xs" style={{ color: colors.textMuted }}>{formatDuration(run.duration_ms)}</span>
                    </div>
                    <p className="text-sm truncate" style={{ color: colors.textCell }}>
                      {run.input_preview || run.input_prompt?.substring(0, 50)}
                    </p>
                    <p className="text-xs mt-1 flex items-center gap-2 flex-wrap" style={{ color: colors.textMuted }}>
                      {run.model && (
                        <span className="px-1.5 py-0.5 rounded font-mono" style={{ background: colors.mutedBg, color: colors.textSecondary }}>{run.model}</span>
                      )}
                      {contextIdOf(run) && <span className="font-mono">#{contextIdOf(run)}</span>}
                      <span>{new Date(run.created_at).toLocaleString()}</span>
                    </p>
                  </div>
                ))}
              </div>
            ) : (
              <div className="px-4 py-8 text-center text-sm" style={{ color: colors.textMuted }}>
                No runs yet
              </div>
            )}
          </div>
        </div>

        {/* Example Prompts */}
        <div style={card} className="p-4">
          <h4 className="font-medium mb-3" style={{ color: colors.textPrimary }}>Example Prompts</h4>
          <div className="space-y-2">
            {EXAMPLE_PROMPTS.map((example) => (
              <button
                key={example}
                type="button"
                data-testid="runner-example-prompt"
                onClick={() => setPrompt(example)}
                className="w-full text-left px-3 py-2 text-sm rounded-lg transition-colors hover:bg-black/5"
                style={{ color: colors.textCell, border: `1px solid ${colors.cardBorder}`, background: 'transparent', cursor: 'pointer' }}
              >
                {example}
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
