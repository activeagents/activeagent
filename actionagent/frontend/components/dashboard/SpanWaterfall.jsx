import React from 'react';
import { ICONS, TYPOGRAPHY } from '../../utils/designTokens';
import InteractionStream, { roleBubble } from './InteractionStream';
import ToolRoster from './ToolRoster';
import {
  Chevron,
  DisclosureLine,
  PreviewLines,
  telemetryColors,
  useDisclosureSet,
} from './TelemetryObject';

// A trace's spans as an expandable waterfall. One implementation, used by the
// Traces view in both themes and by the generations inside an interaction —
// expanding a span anywhere in the dashboard gives you the same panel.

export const SPAN_COLORS = {
  root: '#9ca3af',
  prompt: '#60a5fa',
  generate: '#a855f7',
  llm: '#ef4444',
  thinking: '#fbbf24',
  tool: '#22c55e',
  response: '#2dd4bf',
  embedding: '#818cf8',
};

export const SPAN_SORTS = [
  { id: 'time', label: 'Time', hint: 'Chronological — reads as a waterfall' },
  { id: 'duration', label: 'Slowest', hint: 'Longest-running first' },
  { id: 'name', label: 'Name', hint: 'Group repeated tool calls together' },
];

export const formatDuration = (ms) => {
  if (ms == null) return '—';
  if (ms < 1000) return `${Math.round(ms)}ms`;
  return `${(ms / 1000).toFixed(2)}s`;
};

export const getSpanIcon = (type) => {
  switch (type) {
    case 'root': return ICONS.spans.root;
    case 'prompt': return ICONS.spans.prompt;
    case 'generate': return ICONS.spans.generate;
    case 'llm': return ICONS.spans.llm;
    case 'thinking': return ICONS.spans.thinking;
    case 'tool': return ICONS.spans.tool;
    case 'response': return ICONS.spans.response;
    default: return '-';
  }
};

// Bar width on a log scale, for comparing durations that span orders of
// magnitude. A 5ms tool beside a 13.58s generation is a 2700x range; linearly
// every tool collapses to the same minimum-width stub. Floors at 4% so the
// shortest span is still visibly a bar.
export const logWidthPercent = (duration, longest) => {
  const value = Math.max(duration || 0, 1);
  const max = Math.max(longest || 1, 1);
  if (max <= 1) return 100;

  const ratio = Math.log(value) / Math.log(max);
  return Math.min(100, Math.max(4, ratio * 100));
};

export const sortSpans = (spans, sort) => {
  const list = [...(spans || [])];
  switch (sort) {
    case 'duration':
      return list.sort((a, b) => (b.duration || 0) - (a.duration || 0));
    case 'name':
      return list.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
    default:
      return list.sort((a, b) => (a.start || 0) - (b.start || 0));
  }
};

export const spanTokens = (span) => {
  const tokens = span.tokens || {};
  return (tokens.input || 0) + (tokens.output || 0) + (tokens.thinking || 0);
};

const spanShareLabel = (span, trace) => {
  if (!trace.duration_ms) return formatDuration(span.duration);
  const share = ((span.duration || 0) / trace.duration_ms) * 100;
  return `${formatDuration(span.duration)} · ${share < 1 ? share.toFixed(2) : share.toFixed(1)}%`;
};

// Attribute values that hold JSON payloads (tool inputs/outputs) get
// pretty-printed blocks; everything else renders inline.
const prettyAttribute = (value) => {
  if (typeof value !== 'string') return null;
  try {
    return JSON.stringify(JSON.parse(value), null, 2);
  } catch {
    return null;
  }
};

// Display order for span attributes: system message first, then the tool
// roster, then everything else, with the (long) message history last.
// jsonb storage normalizes key order, so sorting has to happen here.
const attributeRank = (key) => {
  if (key.endsWith('.instructions')) return 0;
  if (key.endsWith('.tools')) return 1;
  if (key.endsWith('.messages')) return 3;
  return 2;
};

// At-a-glance contents for a trace: the latest user input and the final
// output, pulled from span content attributes (either SDK's shape — RubyLLM's
// llm.prompt/llm.completion or ActiveAgent's prompt.input.messages/
// llm.output.message).
export const traceContentPreview = (trace) => {
  const spans = trace.spans || [];
  const attr = (key) => {
    for (const span of spans) {
      const value = (span.attributes || {})[key];
      if (value) return value;
    }
    return null;
  };
  let input = attr('llm.prompt');
  if (!input) {
    const raw = attr('prompt.input.messages');
    if (raw) {
      try {
        const messages = JSON.parse(raw);
        const lastUser = [...messages].reverse().find((m) => m && m.role === 'user' && m.content);
        input = lastUser?.content;
      } catch {
        // not JSON — skip the preview rather than show markup soup
      }
    }
  }
  const output = attr('llm.completion') || attr('llm.output.message');
  return { input, output };
};

// Per-span input/output previews so prompt and generate rows read the same way
// tool rows do — what went in, what came out, at a glance. Labels carry the
// role's colour: blue user input, red agent output/args, amber tool results.
export const spanContentPreview = (span) => {
  const attrs = span.attributes || {};
  let input = null;
  let inputLabel = 'input';
  let inputTone = 'user';
  if (attrs['prompt.input.messages']) {
    try {
      const parsed = JSON.parse(attrs['prompt.input.messages']);
      const lastUser = [...parsed].reverse().find((m) => m && m.role === 'user' && m.content);
      if (typeof lastUser?.content === 'string') input = lastUser.content;
    } catch {
      // not JSON — no preview
    }
  }
  if (!input && attrs['llm.prompt']) input = String(attrs['llm.prompt']);
  if (!input && (attrs['tool.input.args'] || attrs['tool.arguments'])) {
    const args = attrs['tool.input.args'] || attrs['tool.arguments'];
    input = typeof args === 'string' ? args : JSON.stringify(args);
    inputLabel = 'in';
    inputTone = 'assistant';
  }
  let output = null;
  let outputLabel = 'output';
  let outputTone = 'assistant';
  if (attrs['llm.output.message'] || attrs['llm.completion']) {
    output = attrs['llm.output.message'] || attrs['llm.completion'];
  } else if (attrs['tool.output.result'] || attrs['tool.result']) {
    output = attrs['tool.output.result'] || attrs['tool.result'];
    outputLabel = 'out';
    outputTone = 'tool';
  }
  if (output != null && typeof output !== 'string') output = JSON.stringify(output);
  return { input, output, inputLabel, inputTone, outputLabel, outputTone };
};

// Span preview minus whatever the trace header already says — the trace-level
// input/output lines shouldn't repeat on their source spans.
export const dedupedSpanPreview = (span, trace) => {
  const preview = spanContentPreview(span);
  const traceLevel = traceContentPreview(trace);
  if (preview.input && preview.input === traceLevel.input) preview.input = null;
  if (preview.output && preview.output === traceLevel.output) preview.output = null;
  return preview;
};

// Lift a span's content attributes (instructions, prompt messages, tool
// args/results, completions — either SDK shape) into InteractionStream
// messages so span contents read like the Interactions view. Everything else
// stays a raw attribute row.
export const spanMessages = (span) => {
  const rest = { ...(span.attributes || {}) };
  const take = (key) => {
    const value = rest[key];
    delete rest[key];
    return value;
  };
  const messages = [];
  const push = (m) => messages.push({ id: `${span.span_id}-m${messages.length}`, ...m });

  const instructions = take('prompt.input.instructions') || take('llm.instructions');
  if (instructions) push({ role: 'system', content: String(instructions) });

  const rawMessages = take('prompt.input.messages');
  if (rawMessages) {
    try {
      JSON.parse(rawMessages).forEach((m) => {
        if (!m) return;
        push({
          role: m.role || 'user',
          content: typeof m.content === 'string' ? m.content : JSON.stringify(m.content),
          tool_call_id: m.tool_call_id,
          tool_calls: m.tool_calls,
        });
      });
    } catch {
      rest['prompt.input.messages'] = rawMessages;
    }
  }

  const prompt = take('llm.prompt');
  if (prompt) push({ role: 'user', content: String(prompt) });

  const toolArgs = take('tool.input.args') || take('tool.arguments');
  const toolResult = take('tool.output.result') || take('tool.result');
  if (toolArgs || toolResult) {
    const toolName = take('tool.name');
    push({
      role: 'tool',
      tool_name: toolName || (span.name || '').replace(/^tool\./, ''),
      tool_arguments: toolArgs,
      content: toolResult ? String(toolResult) : null,
    });
  }

  const completion = take('llm.completion');
  const outputMessage = take('llm.output.message');
  if (completion || outputMessage) push({ role: 'assistant', content: String(completion || outputMessage) });

  return { messages, rest };
};

// The tool schemas a trace carried (from whichever span recorded them) — lets
// tool messages anywhere in the trace link back to their definition.
export const traceTools = (trace) => {
  for (const span of trace?.spans || []) {
    const raw = (span.attributes || {})['prompt.input.tools'];
    if (!raw) continue;
    try {
      const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
      if (Array.isArray(parsed) && parsed.length > 0) return parsed;
    } catch {
      // unparseable — fall through
    }
  }
  return [];
};

// The panel one span opens into: its timings and ids, its contents rendered as
// a conversation, the tool roster it carried, and every remaining attribute as
// its own expandable line.
export function SpanDetails({ span, darkMode, tools = [] }) {
  const [isAttributeOpen, toggleAttribute] = useDisclosureSet();
  const colors = telemetryColors(darkMode);
  const { messages, rest } = spanMessages(span);

  let rosterTools = null;
  const rawTools = rest['prompt.input.tools'];
  if (rawTools) {
    try {
      const parsed = typeof rawTools === 'string' ? JSON.parse(rawTools) : rawTools;
      if (Array.isArray(parsed) && parsed.length > 0) {
        rosterTools = parsed;
        delete rest['prompt.input.tools'];
      }
    } catch {
      // unparseable — keep the raw attribute row
    }
  }
  const attributes = Object.entries(rest).sort((a, b) => attributeRank(a[0]) - attributeRank(b[0]));
  // A lone tool message condenses to bare call lines — the chip shell earns
  // its keep in conversations, not in a span card.
  const toolMessage = messages.length === 1 && messages[0].role === 'tool' ? messages[0] : null;
  const toolArgs = toolMessage?.tool_arguments == null
    ? null
    : typeof toolMessage.tool_arguments === 'string'
      ? toolMessage.tool_arguments
      : JSON.stringify(toolMessage.tool_arguments);

  return (
    <div
      onClick={(event) => event.stopPropagation()}
      style={{
        margin: '4px 0 8px 0',
        padding: '10px 12px',
        borderRadius: '8px',
        background: colors.panelBg,
        border: `1px solid ${colors.cardBorder}`,
        fontFamily: TYPOGRAPHY.mono,
        fontSize: '12px',
        color: colors.textBody,
        cursor: 'default',
      }}
    >
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 20px' }}>
        <span>duration: {formatDuration(span.duration)}</span>
        <span>status: {span.status || 'OK'}</span>
        {spanTokens(span) > 0 && (
          <span>
            tokens in:{span.tokens.input || 0} out:{span.tokens.output || 0}
            {span.tokens.thinking > 0 ? ` thinking:${span.tokens.thinking}` : ''}
          </span>
        )}
        <span style={{ color: colors.textMuted }}>span: {span.span_id}</span>
      </div>

      {toolMessage && (
        <div style={{ marginTop: '8px', display: 'grid', gap: '4px' }}>
          <div style={{ fontSize: '12px', wordBreak: 'break-all' }}>
            <span style={{ color: roleBubble('tool', darkMode).color }}>⚙ {toolMessage.tool_name}</span>
            {toolArgs && (
              <>
                {' '}
                <span style={{ color: roleBubble('assistant', darkMode).color }}>in:</span>{' '}
                <span style={{ color: colors.textBody }}>{toolArgs}</span>
              </>
            )}
          </div>
          {toolMessage.content && (
            <div style={{ fontSize: '12px' }}>
              <span style={{ color: roleBubble('tool', darkMode).color }}>out:</span>{' '}
              <span
                style={{
                  color: colors.textBody,
                  whiteSpace: 'pre-wrap',
                  display: 'inline-block',
                  maxHeight: '240px',
                  overflowY: 'auto',
                  verticalAlign: 'top',
                  maxWidth: '100%',
                }}
              >
                {toolMessage.content}
              </span>
            </div>
          )}
        </div>
      )}

      {messages.length > 0 && !toolMessage && (
        <div style={{ marginTop: '10px', fontFamily: 'ui-sans-serif, system-ui, sans-serif' }}>
          <InteractionStream messages={messages} darkMode={darkMode} tools={rosterTools || tools} />
        </div>
      )}

      {rosterTools && <ToolRoster tools={rosterTools} darkMode={darkMode} />}

      {attributes.length > 0 && (
        <div style={{ marginTop: '6px', display: 'grid', gap: '2px' }}>
          {attributes.map(([key, value]) => {
            const pretty = key.match(/args|result|input|output/) ? prettyAttribute(value) : null;
            // Plain-text prose (rendered instructions) gets a wrapped block
            // rather than one inline run-on line.
            const prose = !pretty
              && (key.endsWith('.instructions') || key.match(/input|output|result/))
              && typeof value === 'string'
              ? value
              : null;
            const block = pretty || prose;
            if (!block) {
              return (
                <div key={key} style={{ wordBreak: 'break-all' }}>
                  <span style={{ color: colors.textMuted }}>{key}:</span>{' '}
                  {typeof value === 'string' ? value : JSON.stringify(value)}
                </div>
              );
            }
            const attributeKey = `${span.span_id}:${key}`;
            return (
              <DisclosureLine
                key={key}
                label={key}
                body={block}
                prose={!pretty}
                darkMode={darkMode}
                open={isAttributeOpen(attributeKey)}
                onToggle={() => toggleAttribute(attributeKey)}
              />
            );
          })}
        </div>
      )}
    </div>
  );
}

// One span: name, bar, share of the trace, and — until you expand it — a
// preview of its contents. Expanding swaps the preview for the full panel,
// because the panel says the same thing properly.
function SpanRow({ span, trace, darkMode, sort, longest, expanded, onToggle, tools }) {
  const colors = telemetryColors(darkMode);
  const hasDetails = Object.keys(span.attributes || {}).length > 0;
  const preview = expanded ? null : dedupedSpanPreview(span, trace);

  return (
    <>
      <div
        className={`py-0.5 px-1 -mx-1 rounded transition-colors ${
          hasDetails ? `cursor-pointer ${darkMode ? 'hover:bg-white/5' : 'hover:bg-gray-100'}` : ''
        }`}
        // Indentation encodes parent/child nesting, which no longer holds once
        // the list is reordered.
        style={{
          paddingLeft: sort === 'time' ? `${(span.nested || 0) * 16}px` : 0,
          background: expanded ? colors.hoverBg : undefined,
        }}
        onClick={hasDetails ? () => onToggle() : undefined}
        title={hasDetails ? `${span.name} — click for span details` : span.name}
      >
        {/* Name above the track, not beside it: a fixed label column truncated
            every tool.* span to the same unreadable prefix. */}
        <div className="flex items-baseline gap-2 min-w-0">
          <span className="flex-shrink-0" style={{ color: span.type === 'thinking' ? undefined : colors.textMuted }}>
            {getSpanIcon(span.type)}
          </span>
          <span
            className="text-sm font-medium truncate"
            style={{ color: span.error ? colors.bad : colors.textPrimary }}
          >
            {span.name}
          </span>
          <span
            className="text-xs ml-auto flex-shrink-0"
            style={{ fontFamily: TYPOGRAPHY.mono, color: colors.textMuted }}
          >
            {spanShareLabel(span, trace)}
          </span>
          {hasDetails && <Chevron open={expanded} darkMode={darkMode} size={13} style={{ marginLeft: '2px' }} />}
        </div>
        <div className="h-3 relative rounded mt-0.5" style={{ background: colors.trackBg }}>
          <div
            className="absolute h-3 rounded"
            style={{
              background: span.error ? '#f87171' : SPAN_COLORS[span.type] || '#9ca3af',
              // Chronological order earns wall-clock offsets: the bar's
              // position is when it ran. Any other order breaks that link, so
              // bars left-align and become a pure length comparison —
              // otherwise "slowest first" shows short bars scattered across
              // the track and reads as neither.
              left: sort === 'time'
                ? `${trace.duration_ms ? (span.start / trace.duration_ms) * 100 : 0}%`
                : 0,
              width: sort === 'time'
                ? `${trace.duration_ms ? Math.max((span.duration / trace.duration_ms) * 100, 1) : 1}%`
                // Log scale: span durations here span three orders of
                // magnitude (5ms tool, 13.58s llm), so a linear bar renders
                // every tool as the same 1px minimum and compares nothing.
                : `${logWidthPercent(span.duration, longest)}%`,
            }}
          />
        </div>
        {preview && (
          <PreviewLines
            darkMode={darkMode}
            size="11px"
            style={{ marginTop: '2px' }}
            lines={[
              {
                label: preview.inputLabel,
                text: preview.input,
                color: roleBubble(preview.inputTone, darkMode).color,
                max: 160,
              },
              {
                label: preview.outputLabel,
                text: preview.output,
                color: roleBubble(preview.outputTone, darkMode).color,
                max: 160,
              },
            ]}
          />
        )}
      </div>
      {expanded && <SpanDetails span={span} darkMode={darkMode} tools={tools} />}
    </>
  );
}

// `sort` orders the rows; 'time' is the only order in which the bars describe
// a timeline, so the caller draws the axis only for that one.
export default function SpanWaterfall({ trace, darkMode, sort = 'time', tools, keyPrefix = '' }) {
  const [isSpanOpen, toggleSpan] = useDisclosureSet();
  const colors = telemetryColors(darkMode);
  const spans = sortSpans(trace?.spans, sort);
  const knownTools = tools || traceTools(trace);

  if (spans.length === 0) {
    return (
      <div className="text-sm py-2" style={{ color: colors.textMuted }}>
        No spans recorded for this trace.
      </div>
    );
  }

  const longest = Math.max(...spans.map((span) => span.duration || 0), 1);

  return (
    <div className="space-y-2">
      {spans.map((span, index) => {
        // Key on span_id, not index — indices shift when sorted, which would
        // move an open detail panel to another row.
        const spanKey = `${keyPrefix}${span.span_id || index}`;
        return (
          <SpanRow
            key={spanKey}
            span={span}
            trace={trace}
            darkMode={darkMode}
            sort={sort}
            longest={longest}
            tools={knownTools}
            expanded={isSpanOpen(spanKey)}
            onToggle={() => toggleSpan(spanKey)}
          />
        );
      })}
    </div>
  );
}
