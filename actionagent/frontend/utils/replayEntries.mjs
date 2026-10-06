// What the session replay view shows of a timeline entry, and how it reads
// a recording's rrweb events (GET /api/session_recordings/:id/events).

const EXCERPT = 140;

function excerpt(text) {
  const line = String(text ?? '').replace(/\s+/g, ' ').trim();
  return line.length > EXCERPT ? `${line.slice(0, EXCERPT - 1)}…` : line;
}

function tokensLabel(tokens) {
  if (!tokens) return '';
  const input = Number(tokens.input ?? tokens.input_tokens) || 0;
  const output = Number(tokens.output ?? tokens.output_tokens) || 0;
  return input || output ? `${input} in / ${output} out` : '';
}

// The one line a timeline entry is listed by:
//   message  "<role>: <content>", or the tools an assistant turn called
//   llm      the model, and its tokens
//   tool     the tool, and whether it failed
//   browser  the browser tool or action, a console line or a marker
export function entrySummary(entry) {
  switch (entry?.lane) {
    case 'message': {
      const calls = (entry.tool_calls || []).map((call) => call?.name || call?.function?.name).filter(Boolean);
      const text = excerpt(entry.content);
      if (!text && calls.length) return `${entry.role} called ${calls.join(', ')}`;
      if (entry.role === 'tool') return `${entry.tool_name || 'tool'} result: ${text}`;
      return `${entry.role}: ${text}`;
    }
    case 'llm':
      return [entry.model || entry.name || 'model call', tokensLabel(entry.tokens)].filter(Boolean).join(' · ');
    case 'tool':
      return `${entry.name || 'tool'}${entry.error ? ' (failed)' : ''}`;
    case 'browser': {
      const data = entry.data || {};
      if (entry.kind === 'console') return `console ${data.level || 'log'}: ${excerpt(data.message ?? data.value)}`;
      if (entry.kind === 'marker') return `marker: ${excerpt(data.label ?? data.name ?? data.value)}`;
      return data.tool_name || data.action_type || entry.kind || 'browser event';
    }
    default:
      return '';
  }
}

// Whether an entry records a failure.
export function entryFailed(entry) {
  if (!entry) return false;
  if (entry.error === true) return true;
  return ['error', 'ERROR', 'failed'].includes(entry.status);
}

// The rrweb events of a page of event rows, as rrweb replays them: each
// row event's `data`, stamped with the server time it was stored at, so it
// lines up with the timeline. In time order.
export function rrwebEvents(rows = []) {
  return rows
    .filter((row) => row?.kind === 'rrweb')
    .flatMap((row) => row.events || [])
    .filter((event) => event && Number.isFinite(event.at) && event.data && typeof event.data === 'object')
    .map((event) => ({ ...event.data, timestamp: event.at }))
    .sort((a, b) => a.timestamp - b.timestamp);
}

// The mount-relative URL of one page of a recording's rrweb events.
export function recordingEventsPath(recordingId, after = null, limit = 50) {
  const params = new URLSearchParams({ kind: 'rrweb', limit: String(limit) });
  if (after != null) params.set('after', String(after));
  return `/api/session_recordings/${encodeURIComponent(recordingId)}/events?${params}`;
}

// Reads a recording's rrweb events page by page. `fetchPage(path)` returns
// a page's JSON; `onEvents(events, first)` receives each page's events.
// Stops after the last page, once `maxEvents` were read, or when
// `isCancelled()` turns true. Resolves to { count, truncated }.
export async function loadRrwebEvents(recordingId, { fetchPage, onEvents, maxEvents = 50_000, isCancelled = () => false }) {
  let after = null;
  let count = 0;
  for (;;) {
    const page = await fetchPage(recordingEventsPath(recordingId, after));
    if (isCancelled()) return { count, truncated: false };

    const events = rrwebEvents(page?.events);
    if (events.length) {
      onEvents(events, count === 0);
      count += events.length;
    }
    if (!page?.has_more || page.next_after == null) return { count, truncated: false };
    if (count >= maxEvents) return { count, truncated: true };
    after = page.next_after;
  }
}
