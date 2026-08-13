import React, { useState } from 'react';
import Markdown from './Markdown';
import { ToolDetails } from './ToolRoster';

// Shared conversation stream renderer: role-labeled messages with
// click-to-expand details (tool name/arguments/results, durations,
// checksums). Used by the Interactions view and the agent Conversation
// History run detail — same component, different UX context.

const formatMs = (ms) => {
  if (ms == null) return null;
  if (ms < 1000) return `${Math.round(ms)}ms`;
  return `${(ms / 1000).toFixed(2)}s`;
};

// Pretty-print a value that may be a JSON string, object, or plain text.
const prettyJson = (value) => {
  if (value == null) return null;
  if (typeof value === 'object') return JSON.stringify(value, null, 2);
  try {
    return JSON.stringify(JSON.parse(value), null, 2);
  } catch {
    return null;
  }
};

// Tool results often wrap one long human-readable field (browse_page's
// page text, call_agent's output, fetch bodies) in JSON. Surface that
// field as readable content instead of an escaped JSON blob.
const LONG_RESULT_FIELDS = ['text', 'output', 'body', 'content'];

const parseValue = (value) => {
  if (value == null) return null;
  if (typeof value === 'object') return value;
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
};

const toolResultPreview = (message) => {
  const parsed = parseValue(message.tool_result) ?? parseValue(message.content);
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
  const field = LONG_RESULT_FIELDS.find(f => typeof parsed[f] === 'string' && parsed[f].trim().length > 0);
  if (!field) return null;
  const meta = [
    parsed.error && 'error',
    parsed.status != null && `status ${parsed.status}`,
    typeof parsed.url === 'string' && parsed.url.replace(/^https?:\/\//, ''),
    typeof parsed.agent === 'string' && `→ ${parsed.agent}`,
    parsed.truncated && 'truncated'
  ].filter(Boolean).join(' · ');
  const rest = Object.fromEntries(Object.entries(parsed).filter(([k]) => k !== field));
  return { field, meta, body: parsed[field], rest };
};

const hasDetails = (message) =>
  Boolean(
    message.tool_name || message.tool_call_id || message.tool_arguments ||
    message.tool_result || (message.tool_calls || []).length > 0 ||
    message.duration_ms != null || prettyJson(message.content)
  );

// Long tool results and system/developer instructions collapse to a
// tweet-length preview; expanding the message shows the full text.
// User/assistant messages are the conversation itself and stay full.
const PREVIEW_CHARS = 280;
const COLLAPSED_ROLES = ['tool', 'system', 'developer'];

const previewText = (value, max = PREVIEW_CHARS) => value.replace(/\s+/g, ' ').trim().slice(0, max);

// One-line JSON for the collapsed `in:` arguments preview.
const compactJson = (value) => {
  if (value == null) return null;
  if (typeof value === 'object') return JSON.stringify(value);
  try {
    return JSON.stringify(JSON.parse(value));
  } catch {
    return String(value);
  }
};

// A tool-calling assistant message's inputs, whatever shape tool_calls
// takes: provider-style call arrays ({function: {name, arguments}}) or the
// bare arguments object the trace serializer emits.
const callInputs = (message) => {
  const calls = message.tool_calls;
  if (!calls) return [];
  if (Array.isArray(calls)) {
    return calls.map((call) => ({
      name: call.function?.name || call.name || message.tool_name,
      args: compactJson(call.function?.arguments ?? call.arguments ?? call.input),
    }));
  }
  return [{ name: message.tool_name, args: compactJson(calls) }];
};

const hasText = (content) => Boolean(content && String(content).trim() && String(content).trim() !== '—');

// One tool call = one row. An assistant message that only carries tool
// calls merges into its result row(s): the args attach to the matching
// tool message (by call id, else adjacency) and the empty assistant row
// drops. Assistants with prose keep their row; calls with no result yet
// (streaming, errors) stay visible as the assistant row.
const mergeToolTurns = (list) => {
  const messages = (list || []).filter(Boolean);
  const overrides = new Map();
  const dropped = new Set();
  messages.forEach((message, index) => {
    if (message.role !== 'assistant' || hasText(message.content)) return;
    const calls = callInputs(message);
    if (calls.length === 0) return;
    const callIds = new Set();
    if (Array.isArray(message.tool_calls)) {
      message.tool_calls.forEach((call) => call.id && callIds.add(call.id));
    } else if (message.tool_call_id) {
      callIds.add(message.tool_call_id);
    }
    const matched = [];
    for (let j = index + 1; j < messages.length && matched.length < calls.length; j++) {
      const candidate = messages[j];
      if (candidate.role !== 'tool' || dropped.has(j) || overrides.has(j)) break;
      if (callIds.size > 0 && candidate.tool_call_id && !callIds.has(candidate.tool_call_id)) break;
      matched.push(j);
    }
    if (matched.length === 0) return;
    matched.forEach((j, k) => {
      const tool = messages[j];
      const call = calls.find((c) => c.name && c.name === tool.tool_name) || calls[Math.min(k, calls.length - 1)];
      if (call && call.args && !tool.tool_arguments) {
        overrides.set(j, { tool_arguments: call.args, created_at: message.created_at || tool.created_at });
      }
    });
    dropped.add(index);
  });
  return messages
    .map((message, index) => (overrides.has(index) ? { ...message, ...overrides.get(index) } : message))
    .filter((_, index) => !dropped.has(index));
};

const collapsesWhenLong = (message) =>
  COLLAPSED_ROLES.includes(message.role) &&
  typeof message.content === 'string' &&
  previewText(message.content).length >= PREVIEW_CHARS;

// Span-message pill bar: when a message knows its span's place on the
// trace's wall clock, a small positioned pill renders in the row — the
// conversation doubles as a waterfall.
const SpanMessagePill = ({ message, darkMode }) => {
  const total = message.trace_duration_ms || 0;
  if (!total || message.span_duration_ms == null) return null;
  const left = Math.min(((message.span_start_ms || 0) / total) * 100, 98);
  const width = Math.max((message.span_duration_ms / total) * 100, 2);
  const color = message.role === 'tool' ? '#22c55e' : message.role === 'assistant' ? '#ef4444' : '#60a5fa';
  return (
    <span
      title={`${Math.round(message.span_duration_ms)}ms · starts at ${Math.round(message.span_start_ms || 0)}ms of ${Math.round(total)}ms`}
      style={{
        position: 'relative',
        width: '96px',
        height: '5px',
        borderRadius: '999px',
        background: darkMode ? 'rgba(255,255,255,0.08)' : '#f3f4f6',
        flexShrink: 0,
        marginTop: '8px',
        display: 'inline-block',
      }}
    >
      <span
        style={{
          position: 'absolute',
          top: 0,
          bottom: 0,
          left: `${left}%`,
          width: `${Math.min(width, 100 - left)}%`,
          borderRadius: '999px',
          background: color,
        }}
      />
    </span>
  );
};

// Shared stream design primitives — also used by the run activity feed so
// streamed output matches the interaction/trace visual language.
export const streamPreStyle = (darkMode) => ({
  background: darkMode ? 'rgba(0,0,0,0.35)' : '#f3f4f6',
  color: darkMode ? '#ffffff' : '#111827',
  borderRadius: '6px',
  padding: '8px 10px',
  fontSize: '12px',
  overflowX: 'auto',
  margin: 0,
});

export const roleBubble = (role, darkMode) => {
  switch (role) {
    case 'user':
      return darkMode
        ? { background: 'rgba(59,130,246,0.15)', color: '#93c5fd', label: 'User' }
        : { background: '#eff6ff', color: '#1d4ed8', label: 'User' };
    case 'assistant':
      return darkMode
        ? { background: 'rgba(239,68,68,0.12)', color: '#fca5a5', label: 'Assistant' }
        : { background: '#fef2f2', color: '#b91c1c', label: 'Assistant' };
    case 'tool':
      return darkMode
        ? { background: 'rgba(245,158,11,0.12)', color: '#fcd34d', label: 'Tool' }
        : { background: '#fffbeb', color: '#b45309', label: 'Tool' };
    case 'system':
      return darkMode
        ? { background: 'rgba(139,92,246,0.15)', color: '#c4b5fd', label: 'System' }
        : { background: '#f5f3ff', color: '#6d28d9', label: 'System' };
    case 'developer':
      return darkMode
        ? { background: 'rgba(20,184,166,0.15)', color: '#5eead4', label: 'Dev' }
        : { background: '#f0fdfa', color: '#0f766e', label: 'Dev' };
    default:
      return darkMode
        ? { background: 'rgba(255,255,255,0.08)', color: 'rgba(255,255,255,0.7)', label: role }
        : { background: '#f3f4f6', color: '#374151', label: role };
  }
};

// `tools` (optional): the tool schemas in play for this conversation, so an
// expanded tool message can show where its tool comes from and what it does.
export default function InteractionStream({ messages, darkMode, tools }) {
  const [expandedMessages, setExpandedMessages] = useState({});

  const toggleMessage = (id) =>
    setExpandedMessages((prev) => ({ ...prev, [id]: !prev[id] }));

  const colors = {
    textPrimary: darkMode ? '#ffffff' : '#111827',
    textSecondary: darkMode ? 'rgba(255,255,255,0.6)' : '#6b7280',
    textMuted: darkMode ? 'rgba(255,255,255,0.4)' : '#9ca3af',
  };

  const stream = mergeToolTurns(messages);

  return (
    <div className="space-y-3">
      {stream.map((message) => {
        const bubble = roleBubble(message.role, darkMode);
        const isExpanded = !!expandedMessages[message.id];
        const collapsed = collapsesWhenLong(message) && !isExpanded;
        const expandable = hasDetails(message) || collapsesWhenLong(message);
        const argsJson = prettyJson(message.tool_arguments);
        const resultJson = prettyJson(message.tool_result) || prettyJson(message.content);
        const toolCallsJson =
          message.tool_calls && (!Array.isArray(message.tool_calls) || message.tool_calls.length > 0)
            ? prettyJson(message.tool_calls)
            : null;
        const resultPreview = message.role === 'tool' ? toolResultPreview(message) : null;
        const toolSchema = message.tool_name
          ? (tools || []).find((tool) => tool && tool.name === message.tool_name)
          : null;
        const argsCompact = message.role === 'tool' ? compactJson(message.tool_arguments) : null;
        // A consolidated call row: agent (assistant, red) supplied the
        // input, the tool (amber) answered with the output — both roles
        // stay visible on their own line.
        const mergedCall = message.role === 'tool' && Boolean(argsCompact);
        const assistantTone = roleBubble('assistant', darkMode);
        const toolTone = roleBubble('tool', darkMode);
        // When the preceding assistant row carries this call's input, the
        // tool row only needs the output side.
        const inputCarriedByAssistant =
          message.role === 'tool' &&
          !message.tool_arguments &&
          stream.some(
            (m) =>
              m &&
              m.role === 'assistant' &&
              ((message.tool_call_id && m.tool_call_id === message.tool_call_id) ||
                (Array.isArray(m.tool_calls) && m.tool_calls.some((call) => call.id && call.id === message.tool_call_id)))
          );
        const assistantCalls =
          message.role === 'assistant' && !hasText(message.content) ? callInputs(message) : [];
        const preStyle = streamPreStyle(darkMode);
        return (
          <div key={message.id}>
            <div
              className={`flex gap-3 items-start rounded-lg -mx-2 px-2 py-1 ${expandable ? 'cursor-pointer' : ''}`}
              onClick={expandable ? () => toggleMessage(message.id) : undefined}
              style={isExpanded ? { background: darkMode ? 'rgba(255,255,255,0.04)' : 'rgba(0,0,0,0.03)' } : {}}
            >
              <span className="flex flex-col gap-1 flex-shrink-0 mt-0.5" style={{ minWidth: '72px' }}>
                {(mergedCall ? [assistantTone, toolTone] : [bubble]).map((tone) => (
                  <span
                    key={tone.label}
                    className="px-2 py-0.5 rounded text-xs font-medium"
                    style={{ background: tone.background, color: tone.color, textAlign: 'center' }}
                  >
                    {tone.label}
                  </span>
                ))}
              </span>
              <div className="min-w-0 flex-1">
                <div className="text-sm break-words" style={{ color: colors.textPrimary }}>
                  {message.role === 'tool' ? (
                    // Tool rows always read as a compact in/out summary — the
                    // full arguments and result live in the expanded details
                    // below, in that order.
                    <span style={{ display: 'grid', gap: '2px' }}>
                      {argsCompact && !inputCarriedByAssistant && (
                        <span className="font-mono text-xs break-words">
                          {message.tool_name && (
                            // The function name heads its own call line — this
                            // is what took the input and rendered the result.
                            <span style={{ color: toolTone.color }}>⚙ {message.tool_name} </span>
                          )}
                          <span style={{ color: mergedCall ? assistantTone.color : colors.textMuted }}>in:</span>{' '}
                          {previewText(argsCompact, 180)}
                          {argsCompact.length > 180 ? '…' : ''}
                        </span>
                      )}
                      {resultPreview ? (
                        <span>
                          {message.tool_name && !(argsCompact && !inputCarriedByAssistant) && (
                            <span className="font-mono text-xs mr-1" style={{ color: toolTone.color }}>⚙ {message.tool_name}</span>
                          )}
                          {(argsCompact || inputCarriedByAssistant) && (
                            <span className="font-mono text-xs mr-1" style={{ color: mergedCall ? toolTone.color : colors.textMuted }}>out:</span>
                          )}
                          {resultPreview.meta && (
                            <span className="font-mono text-xs mr-2" style={{ color: colors.textMuted }}>
                              {resultPreview.meta}
                            </span>
                          )}
                          “{resultPreview.body.replace(/\s+/g, ' ').trim().slice(0, 180)}
                          {resultPreview.body.length > 180 ? '…' : ''}”
                        </span>
                      ) : message.content ? (
                        <span>
                          {message.tool_name && !(argsCompact && !inputCarriedByAssistant) && (
                            <span className="font-mono text-xs mr-1" style={{ color: toolTone.color }}>⚙ {message.tool_name}</span>
                          )}
                          {(argsCompact || inputCarriedByAssistant) && (
                            <span className="font-mono text-xs mr-1" style={{ color: mergedCall ? toolTone.color : colors.textMuted }}>out:</span>
                          )}
                          “{previewText(message.content, 180)}
                          {message.content.replace(/\s+/g, ' ').trim().length > 180 ? '…' : ''}”
                        </span>
                      ) : (
                        <span className="whitespace-pre-wrap">
                          {message.tool_name ? `→ ${message.tool_name}(...)` : '—'}
                        </span>
                      )}
                    </span>
                  ) : collapsed ? (
                    <span style={{ color: colors.textSecondary }}>{previewText(message.content)}…</span>
                  ) : assistantCalls.length > 0 ? (
                    // A tool-calling turn with no prose: use the row for the
                    // call's input instead of an empty dash.
                    <span style={{ display: 'grid', gap: '2px' }}>
                      {assistantCalls.map((call, callIndex) => (
                        <span key={callIndex} className="font-mono text-xs break-words">
                          {call.name && <span style={{ color: colors.textMuted }}>{call.name} </span>}
                          <span style={{ color: colors.textMuted }}>in:</span>{' '}
                          {call.args ? (
                            <>
                              {previewText(call.args, 180)}
                              {call.args.length > 180 ? '…' : ''}
                            </>
                          ) : (
                            '—'
                          )}
                        </span>
                      ))}
                    </span>
                  ) : (
                    <Markdown text={message.content || '—'} />
                  )}
                </div>
                <div className="text-xs mt-0.5 font-mono flex items-center gap-2 flex-wrap" style={{ color: colors.textMuted }}>
                  {message.created_at && <span>{new Date(message.created_at).toLocaleTimeString()}</span>}
                  {message.tool_name && message.role !== 'tool' && (
                    <span
                      className="px-1.5 py-0.5 rounded"
                      style={{ background: bubble.background, color: bubble.color }}
                    >
                      ⚙ {message.tool_name}
                    </span>
                  )}
                  {message.duration_ms != null && <span>{formatMs(message.duration_ms)}</span>}
                  {(message.tool_calls || []).length > 0 && (
                    <span>{message.tool_calls.length} tool call{message.tool_calls.length > 1 ? 's' : ''}</span>
                  )}
                  {message.content_checksum && (
                    <span title="Content fingerprint">🔒 {message.content_checksum.slice(0, 8)}</span>
                  )}
                </div>
              </div>
              <SpanMessagePill message={message} darkMode={darkMode} />
              {expandable && (
                <svg
                  className={`w-3.5 h-3.5 mt-1 flex-shrink-0 transition-transform ${isExpanded ? 'rotate-180' : ''}`}
                  fill="none" stroke="currentColor" viewBox="0 0 24 24"
                  style={{ color: colors.textMuted }}
                >
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
                </svg>
              )}
            </div>

            {isExpanded && (
              <div
                className="ml-3 mt-1 mb-2 pl-4 space-y-2 border-l-2"
                style={{ borderColor: bubble.color + '55' }}
              >
                <div className="flex flex-wrap gap-x-5 gap-y-1 text-xs font-mono" style={{ color: colors.textSecondary }}>
                  {message.created_at && <span>{new Date(message.created_at).toLocaleString()}</span>}
                  {message.tool_call_id && <span>call: {message.tool_call_id}</span>}
                  {message.duration_ms != null && <span>took {formatMs(message.duration_ms)}</span>}
                  {message.content_checksum && <span>🔒 {message.content_checksum}</span>}
                </div>
                {argsJson && (
                  <div>
                    <div className="text-xs uppercase tracking-wide mb-1" style={{ color: mergedCall ? assistantTone.color : colors.textMuted }}>
                      Arguments{mergedCall ? ' · from the agent' : ''}
                    </div>
                    <pre style={preStyle}>{argsJson}</pre>
                  </div>
                )}
                {resultPreview ? (
                  <div>
                    <div className="text-xs uppercase tracking-wide mb-1" style={{ color: mergedCall ? toolTone.color : colors.textMuted }}>
                      Result{mergedCall ? ' · from the tool' : ''}
                    </div>
                    {Object.keys(resultPreview.rest).length > 0 && (
                      <pre style={preStyle}>{JSON.stringify(resultPreview.rest, null, 2)}</pre>
                    )}
                    <div className="text-xs uppercase tracking-wide mt-2 mb-1" style={{ color: colors.textMuted }}>
                      {resultPreview.field} · {resultPreview.body.length.toLocaleString()} chars
                    </div>
                    <pre style={{ ...preStyle, whiteSpace: 'pre-wrap', maxHeight: '320px', overflowY: 'auto' }}>
                      {resultPreview.body.slice(0, 8000)}
                      {resultPreview.body.length > 8000 ? '\n…' : ''}
                    </pre>
                  </div>
                ) : resultJson ? (
                  <div>
                    <div className="text-xs uppercase tracking-wide mb-1" style={{ color: colors.textMuted }}>
                      {message.role === 'tool' ? 'Result' : 'Content (parsed)'}
                    </div>
                    <pre style={preStyle}>{resultJson}</pre>
                  </div>
                ) : message.role === 'tool' && message.content ? (
                  <div>
                    <div className="text-xs uppercase tracking-wide mb-1" style={{ color: mergedCall ? toolTone.color : colors.textMuted }}>
                      Result{mergedCall ? ' · from the tool' : ''} · {message.content.length.toLocaleString()} chars
                    </div>
                    <pre style={{ ...preStyle, whiteSpace: 'pre-wrap', maxHeight: '320px', overflowY: 'auto' }}>
                      {message.content.slice(0, 8000)}
                      {message.content.length > 8000 ? '\n…' : ''}
                    </pre>
                  </div>
                ) : null}
                {toolCallsJson && (
                  <div>
                    <div className="text-xs uppercase tracking-wide mb-1" style={{ color: colors.textMuted }}>Requested tool calls</div>
                    <pre style={preStyle}>{toolCallsJson}</pre>
                  </div>
                )}
                {toolSchema && (
                  <div>
                    <div className="text-xs uppercase tracking-wide mb-1" style={{ color: colors.textMuted }}>
                      Tool definition
                    </div>
                    <ToolDetails tool={toolSchema} darkMode={darkMode} />
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
