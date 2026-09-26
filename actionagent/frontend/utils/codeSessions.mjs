// Settings -> Integrations: checkout sandboxes and the Claude Code sessions
// run inside them. Everything here is derived from what the API returns — a
// sandbox summary, a code session's summary or details, and the stream-json
// events Claude Code printed — so the cards only lay rows out. Pure, and
// imports nothing, so the node tests can pin it.
//
// A code session's transcript is Claude Code's `--output-format stream-json`
// output, one JSON object per line, stored as it arrived:
//
//   { type: "system", subtype: "init", model, tools, permissionMode, cwd }
//   { type: "assistant", message: { content: [text | tool_use | thinking] } }
//   { type: "user", message: { content: [tool_result] } }
//   { type: "result", subtype: "success" | "error_…", is_error, num_turns,
//     total_cost_usd, duration_ms, permission_denials }
//   { type: "raw", text }   — a line the backend could not parse as JSON
//
// A CLI release can add event and block types; anything unrecognised still
// renders, as its JSON, rather than vanishing from the transcript.

export const SANDBOX_POLL_INTERVAL_MS = 2000;
export const CODE_SESSION_POLL_INTERVAL_MS = 1500;

// Polls in a row that may fail (a restarting server, a dropped connection)
// before a card stops asking and says so.
export const MAX_POLL_FAILURES = 5;

// Whether a poll that failed should stop rather than try again: the server
// refused it (a 4xx: signed out, forbidden, not found), which asking again
// will not change, or it has now failed MAX_POLL_FAILURES times in a row.
// `status` is the HTTP status, or null when no answer came back at all.
export const pollGivesUp = (status, failuresInARow) => (
  (status != null && status >= 400 && status < 500) || failuresInARow >= MAX_POLL_FAILURES
);

// How much of a tool's output the transcript shows inline. Results can be
// whole files (the server already cuts any string past 4,000 characters).
export const TOOL_RESULT_PREVIEW_CHARS = 600;
export const TOOL_RESULT_PREVIEW_LINES = 12;
const TOOL_INPUT_PREVIEW_CHARS = 120;
const UNKNOWN_PREVIEW_CHARS = 300;

export const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

export const truncate = (text, max) => {
  const value = String(text ?? '');
  return value.length > max ? `${value.slice(0, max - 1)}…` : value;
};

const humanize = (value) => String(value || '').replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase());

// One line, for a summary that sits beside a label.
const oneLine = (text) => String(text ?? '').replace(/\s+/g, ' ').trim();

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

const compactJson = (value) => {
  try {
    return JSON.stringify(value) ?? String(value);
  } catch (_error) {
    return String(value);
  }
};

// --- formatting -------------------------------------------------------------

// Money as Claude Code reports it: "$0.42". Sub-cent figures keep four
// decimals, since "$0.00" reads as no spend. Nothing reported → null, so a
// line can leave the part out.
export const fmtCostUsd = (value) => {
  if (value == null || value === '' || Number.isNaN(Number(value))) return null;
  const n = Number(value);
  if (n === 0) return '$0.00';
  if (Math.abs(n) < 0.01) return `$${n.toFixed(4)}`;
  return `$${n.toFixed(2)}`;
};

// 850 → "850ms", 12340 → "12.3s", 125000 → "2m 5s", 3723000 → "1h 2m".
export const fmtDurationMs = (ms) => {
  if (ms == null || ms === '' || Number.isNaN(Number(ms))) return null;
  const n = Math.max(0, Number(ms));
  if (n < 1000) return `${Math.round(n)}ms`;
  if (n < 60000) return `${(n / 1000).toFixed(1).replace(/\.0$/, '')}s`;
  const totalSeconds = Math.round(n / 1000);
  if (totalSeconds < 3600) return `${Math.floor(totalSeconds / 60)}m ${totalSeconds % 60}s`;
  return `${Math.floor(totalSeconds / 3600)}h ${Math.floor((totalSeconds % 3600) / 60)}m`;
};

// "Succeeded · 3 turns · $0.12 · 42.5s": a label followed by whichever of
// the counts were reported. Reads a session summary or a result event, which
// name them alike.
export const resultLine = (label, { num_turns: turns, total_cost_usd: cost, duration_ms: duration } = {}) => [
  label,
  turns == null || turns === '' ? null : plural(Number(turns), 'turn'),
  fmtCostUsd(cost),
  fmtDurationMs(duration),
].filter(Boolean).join(' · ');

// "expires in 1h 52m", "expires in 4m", "past its expiry" — an app_runtime
// sandbox lives two hours, and its processes stop when it is reaped.
export const fmtExpiry = (iso, now = Date.now()) => {
  if (!iso) return null;
  const at = new Date(iso).getTime();
  if (Number.isNaN(at)) return null;
  const mins = Math.ceil((at - now) / 60000);
  if (mins <= 0) return 'past its expiry';
  if (mins < 60) return `expires in ${mins}m`;
  return `expires in ${Math.floor(mins / 60)}h${mins % 60 ? ` ${mins % 60}m` : ''}`;
};

// What a failed request says, in the server's own words when it gave any.
// The API answers `{ error }`, a model's `{ errors: [...] }`, or a refused
// quota's `{ error: "Plan limit reached", message }`.
export const apiErrorMessage = (data, fallback) => {
  const listed = (value) => (Array.isArray(value) ? value.filter(Boolean).join(', ') : (typeof value === 'string' ? value : ''));
  const body = isObject(data) ? data : {};
  const error = listed(body.error) || listed(body.errors);
  const message = typeof body.message === 'string' ? body.message : '';
  if (error && message) return `${error}: ${message}`;
  return error || message || fallback;
};

// --- statuses ---------------------------------------------------------------

// Tones the cards map onto their own classes: success, error, progress
// (something is still happening) and neutral.
const SANDBOX_STATUSES = {
  pending: { label: 'Queued', tone: 'progress' },
  provisioning: { label: 'Booting', tone: 'progress' },
  ready: { label: 'Ready', tone: 'success' },
  running: { label: 'Running', tone: 'success' },
  completed: { label: 'Completed', tone: 'neutral' },
  // Expired is also where Stop leaves a sandbox.
  expired: { label: 'Stopped', tone: 'neutral' },
  failed: { label: 'Failed', tone: 'error' },
};

export const sandboxStatus = (status) => SANDBOX_STATUSES[status] || { label: humanize(status) || 'Unknown', tone: 'neutral' };

// Still being checked out and booted: the card polls it every 2s until it
// settles (ready, failed, expired — or anything else it cannot leave by
// itself).
export const isSandboxBooting = (sandbox) => ['pending', 'provisioning'].includes(sandbox?.status);

// Ready for a Claude Code session: the API refuses any other status.
export const isSandboxReady = (sandbox) => sandbox?.status === 'ready';

const CODE_SESSION_STATUSES = {
  queued: { label: 'Queued', tone: 'progress' },
  running: { label: 'Running', tone: 'progress' },
  succeeded: { label: 'Succeeded', tone: 'success' },
  failed: { label: 'Failed', tone: 'error' },
  cancelled: { label: 'Cancelled', tone: 'neutral' },
};

export const codeSessionStatus = (status) => CODE_SESSION_STATUSES[status] || { label: humanize(status) || 'Unknown', tone: 'neutral' };

export const isCodeSessionActive = (session) => ['queued', 'running'].includes(session?.status);

export const isCodeSessionFinished = (session) => ['succeeded', 'failed', 'cancelled'].includes(session?.status);

// Whether the server may still record a finished session's diff (and more
// of its transcript): a session cancelled while running is finished at
// once, but its Claude Code is still stopping. The server says so in
// diff_pending; one that does not send it has nothing still to come.
export const isCodeSessionDiffPending = (session) => isCodeSessionFinished(session) && session?.diff_pending === true;

// Finished, with nothing more to record: what a poll of the session runs
// until.
export const isCodeSessionSettled = (session) => isCodeSessionFinished(session) && !isCodeSessionDiffPending(session);

// Cancelled, and settled with no diff: the job recorded that Claude Code
// never ran (cancelled in the queue, or refused by the backend before it
// started), so no transcript or diff will ever come.
export const codeSessionNeverRan = (session) => session?.status === 'cancelled'
  && isCodeSessionSettled(session) && session?.diff == null && !(Number(session?.event_count) > 0);

// What a session has to show for itself so far: its event count while it
// runs, the turns, cost and duration Claude Code reported once it finished.
// Beside a status badge, so without the status.
export const sessionCounts = (session) => {
  if (!isCodeSessionFinished(session)) {
    const count = Number(session?.event_count) || 0;
    return count > 0 ? plural(count, 'event') : '';
  }
  return resultLine(null, session);
};

// The same, led by the status in words: "Succeeded · 3 turns · $0.12 · 42.5s".
export const sessionResultLine = (session) => [codeSessionStatus(session?.status).label, sessionCounts(session)]
  .filter(Boolean).join(' · ');

// The prompt's first line, for the list.
export const sessionTitle = (prompt, max = 80) => {
  const first = String(prompt || '').split('\n').map((line) => line.trim()).find(Boolean) || '';
  return truncate(first, max) || '(empty prompt)';
};

// --- lists ------------------------------------------------------------------

// Replaces the row with the same `key` in place (merged, so a poll's details
// keep whatever the summary had), or puts a new one first — the API lists
// newest first.
export const upsertBy = (list, item, key) => {
  if (!item || item[key] == null) return list;
  const index = list.findIndex((row) => row[key] === item[key]);
  if (index === -1) return [item, ...list];
  const next = list.slice();
  next[index] = { ...list[index], ...item };
  return next;
};

// Updates the row with the same `key` (merged), and only that: a poll that
// answers after its sandbox was stopped must not put it back.
export const replaceBy = (list, item, key) => (
  item && list.some((row) => row[key] === item[key]) ? upsertBy(list, item, key) : list
);

// A code session's details without its transcript, for the list.
export const sessionSummary = (details) => {
  if (!details) return details;
  const { events, events_offset: offset, dropped_events_count: dropped, diff, ...summary } = details;
  return summary;
};

// The caller's checkout sandboxes by repository, newest first within each.
// Sandboxes of a repository no longer selected are listed apart: they still
// run until stopped or reaped, so they must stay reachable.
export const groupSandboxes = (sandboxes, repositoryNames) => {
  const names = new Set(repositoryNames || []);
  const byRepository = {};
  const others = [];
  (sandboxes || []).forEach((sandbox) => {
    if (!sandbox || sandbox.status === 'expired') return;
    if (sandbox.sandbox_type && sandbox.sandbox_type !== 'app_runtime') return;
    if (names.has(sandbox.repository)) {
      (byRepository[sandbox.repository] ||= []).push(sandbox);
    } else {
      others.push(sandbox);
    }
  });
  return { byRepository, others };
};

// Appends a details response to the events already held. The response
// carries the events from `events_offset` on (the `after` asked for, clamped
// to what is stored), so the transcript is rebuilt from that position: a
// repeated or overlapping poll never duplicates an event.
export const mergeEvents = (current, details) => {
  const held = Array.isArray(current) ? current : [];
  const incoming = Array.isArray(details?.events) ? details.events : [];
  const offset = Math.max(0, Math.min(Number(details?.events_offset) || 0, held.length));
  return [...held.slice(0, offset), ...incoming];
};

// --- tool input summaries ---------------------------------------------------

// A path under the checkout reads relative to it: the workspace root is
// long and the same for every call.
const relativePath = (value, cwd) => {
  const path = String(value ?? '');
  if (!cwd) return path;
  const root = String(cwd).replace(/\/+$/, '');
  if (path === root) return '.';
  return path.startsWith(`${root}/`) ? path.slice(root.length + 1) : path;
};

// Per tool, which input field says what the call does.
const TOOL_SUMMARIES = {
  Bash: (input) => input.command,
  Read: (input, cwd) => relativePath(input.file_path, cwd),
  Write: (input, cwd) => relativePath(input.file_path, cwd),
  Edit: (input, cwd) => relativePath(input.file_path, cwd),
  MultiEdit: (input, cwd) => {
    const edits = Array.isArray(input.edits) ? ` (${plural(input.edits.length, 'edit')})` : '';
    return `${relativePath(input.file_path, cwd)}${edits}`;
  },
  NotebookEdit: (input, cwd) => relativePath(input.notebook_path, cwd),
  NotebookRead: (input, cwd) => relativePath(input.notebook_path, cwd),
  Glob: (input, cwd) => (input.path ? `${input.pattern} in ${relativePath(input.path, cwd)}` : input.pattern),
  Grep: (input, cwd) => [
    `"${input.pattern}"`,
    input.path && `in ${relativePath(input.path, cwd)}`,
    input.glob && `(${input.glob})`,
  ].filter(Boolean).join(' '),
  LS: (input, cwd) => relativePath(input.path, cwd),
  WebFetch: (input) => input.url,
  WebSearch: (input) => input.query,
  Task: (input) => input.description || input.prompt,
  Agent: (input) => input.description || input.prompt,
  TodoWrite: (input) => (Array.isArray(input.todos) ? plural(input.todos.length, 'todo') : ''),
  BashOutput: (input) => input.bash_id,
  KillShell: (input) => input.shell_id,
  KillBash: (input) => input.shell_id,
  Skill: (input) => input.skill || input.command,
  SlashCommand: (input) => input.command,
};

// Fields that usually say what an unfamiliar tool (an MCP server's) does.
const GENERIC_KEYS = ['command', 'file_path', 'path', 'url', 'query', 'pattern', 'description', 'name', 'prompt'];

// "name + short input": the part of a tool call's input that says what it
// did, on one line — the command it ran, the file it read, the pattern it
// searched for. Unfamiliar tools show a common field, or their input as JSON.
export const summarizeToolInput = (name, input, { cwd } = {}) => {
  if (input == null) return '';
  if (!isObject(input)) return truncate(oneLine(typeof input === 'string' ? input : compactJson(input)), TOOL_INPUT_PREVIEW_CHARS);

  const known = TOOL_SUMMARIES[name];
  let summary = known ? known(input, cwd) : null;
  if (summary == null || summary === '') {
    const key = GENERIC_KEYS.find((field) => typeof input[field] === 'string' && input[field].trim());
    if (key) {
      summary = ['file_path', 'path'].includes(key) ? relativePath(input[key], cwd) : input[key];
    } else {
      summary = Object.keys(input).length ? compactJson(input) : '';
    }
  }
  return truncate(oneLine(summary), TOOL_INPUT_PREVIEW_CHARS);
};

// --- tool results -----------------------------------------------------------

// A tool_result's content is a string or a list of blocks (text, image, …).
export const toolResultText = (content) => {
  if (content == null) return '';
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content.map((block) => {
      if (typeof block === 'string') return block;
      if (block?.type === 'text') return block.text ?? '';
      if (block?.type === 'image') return '[image]';
      return compactJson(block);
    }).join('\n');
  }
  return compactJson(content);
};

// The inline preview of a tool's output: its first lines, cut at a length.
export const previewText = (text, { chars = TOOL_RESULT_PREVIEW_CHARS, lines = TOOL_RESULT_PREVIEW_LINES } = {}) => {
  const full = String(text ?? '').replace(/\s+$/, '');
  let preview = full.split('\n').slice(0, lines).join('\n');
  if (preview.length > chars) preview = preview.slice(0, chars);
  const truncated = preview.length < full.length;
  return { text: truncated ? `${preview.replace(/\s+$/, '')}…` : preview, truncated };
};

// --- events → rows -----------------------------------------------------------

const RESULT_ERROR_LABELS = {
  error_max_turns: 'Stopped: max turns reached',
  error_during_execution: 'Error during execution',
};

// A result event reports a failure through is_error or an error subtype.
export const resultEventFailed = (event) => event?.is_error === true || (event?.subtype != null && event.subtype !== 'success');

const resultLabel = (event) => {
  if (!resultEventFailed(event)) return 'Done';
  if (RESULT_ERROR_LABELS[event.subtype]) return RESULT_ERROR_LABELS[event.subtype];
  // An is_error "success", or a subtype this code does not know yet.
  const subtype = String(event.subtype || '').replace(/^error_?/, '').replace(/_/g, ' ').trim();
  return subtype && event.subtype !== 'success' ? `Error (${subtype})` : 'Error';
};

const systemRow = (event) => {
  if (event.subtype === 'init') {
    const tools = Array.isArray(event.tools) ? plural(event.tools.length, 'tool') : null;
    const parts = [event.model && `model ${event.model}`, event.permissionMode && `${event.permissionMode} mode`, tools];
    return { kind: 'system', text: ['Session started', ...parts.filter(Boolean)].join(' · ') };
  }
  if (event.subtype === 'compact_boundary') return { kind: 'system', text: 'Conversation compacted' };
  if (event.subtype === 'api_retry') {
    // "API retry 2/10 · 529 Overloaded", leaving out whatever was not sent.
    const attempt = event.attempt ?? '?';
    const count = event.max_retries != null ? `${attempt}/${event.max_retries}` : String(attempt);
    const cause = [event.error_status, event.error].filter((part) => part != null && part !== '').join(' ');
    return { kind: 'system', text: [`API retry ${count}`, cause].filter(Boolean).join(' · ') };
  }
  return { kind: 'system', text: event.subtype ? `System: ${humanize(event.subtype).toLowerCase()}` : 'System event' };
};

const unknownRow = (label, value) => ({
  kind: 'unknown',
  label: String(label || 'event'),
  text: truncate(compactJson(value), UNKNOWN_PREVIEW_CHARS),
});

// One content block of an assistant or user message.
const blockRows = (block, role, context) => {
  if (typeof block === 'string') return block.trim() ? [{ kind: role === 'assistant' ? 'text' : 'user_text', text: block }] : [];
  if (!isObject(block)) return [];

  switch (block.type) {
    case 'text':
      if (!String(block.text ?? '').trim()) return [];
      return [{ kind: role === 'assistant' ? 'text' : 'user_text', text: block.text }];
    case 'thinking':
      return String(block.thinking ?? '').trim() ? [{ kind: 'thinking', text: block.thinking }] : [];
    case 'redacted_thinking':
      return [{ kind: 'thinking', text: '(redacted)' }];
    case 'tool_use':
    case 'server_tool_use': {
      const name = String(block.name || 'tool');
      if (block.id) context.toolNames[block.id] = name;
      return [{ kind: 'tool_use', name, summary: summarizeToolInput(name, block.input, context), id: block.id || null }];
    }
    case 'tool_result': {
      const { text, truncated } = previewText(toolResultText(block.content));
      return [{
        kind: 'tool_result',
        name: context.toolNames[block.tool_use_id] || null,
        text,
        truncated,
        isError: block.is_error === true,
      }];
    }
    default:
      return [unknownRow(`${role} ${block.type || 'block'}`, block)];
  }
};

const messageRows = (event, context) => {
  const content = event.message?.content;
  if (typeof content === 'string') return blockRows(content, event.type, context);
  if (!Array.isArray(content)) return [unknownRow(event.type, event)];
  return content.flatMap((block) => blockRows(block, event.type, context));
};

// The rows one stream-json event renders as — none for an event with nothing
// to show (an empty text block). `context` carries what a later event needs
// from an earlier one: the checkout's path (from init) and each tool call's
// name by id (for its result).
export const eventRows = (event, context = { toolNames: {} }) => {
  context.toolNames ||= {};
  if (!isObject(event)) {
    return event == null || event === '' ? [] : [{ kind: 'raw', text: typeof event === 'string' ? event : compactJson(event) }];
  }

  // Rows a subagent (Task) produced carry the id of the call that started it.
  const nested = Boolean(event.parent_tool_use_id);
  const mark = (rows) => (nested ? rows.map((row) => ({ ...row, nested: true })) : rows);

  switch (event.type) {
    case 'system':
      if (event.subtype === 'init' && event.cwd) context.cwd = event.cwd;
      return [systemRow(event)];
    case 'assistant':
    case 'user':
      return mark(messageRows(event, context));
    case 'result': {
      const denials = Array.isArray(event.permission_denials) ? event.permission_denials.length : 0;
      const line = resultLine(resultLabel(event), event);
      return [{
        kind: 'result',
        tone: resultEventFailed(event) ? 'error' : 'success',
        text: denials ? `${line} · ${plural(denials, 'permission denial')}` : line,
      }];
    }
    case 'raw':
      return event.text == null || event.text === '' ? [] : [{ kind: 'raw', text: String(event.text) }];
    default:
      return [unknownRow(event.type, event)];
  }
};

// The rows of a whole transcript, each keyed by its event's index so rows
// stay stable as polls append to it.
export const transcriptRows = (events) => {
  const context = { toolNames: {} };
  return (events || []).flatMap((event, index) => eventRows(event, context).map((row, position) => ({
    ...row,
    key: `${index}:${position}`,
  })));
};

// --- diff -------------------------------------------------------------------

// The line that opens one file's section of `git diff` (a merge conflict's
// is "diff --cc").
const DIFF_FILE_START = /^diff (--git|--cc|--combined) /;

// What CodeSession#diff= appends when it cuts a diff short.
const DIFF_TRUNCATED = '… diff truncated';

// Each line of a unified diff with what it is, for coloring. Read in order:
// a file's header runs from its "diff --git" line to its first "@@", and
// every line there is meta, whatever it starts with — "--- a/x" and
// "+++ b/x", or "--- i/x" and "+++ w/x" under diff.mnemonicPrefix, or "--- x"
// under diff.noprefix, since the user's git config and the checkout's own
// decide the prefixes. Inside a hunk each line starts with one marker column
// per parent (two in a merge conflict's combined diff), so a removed line
// that reads "-- x" stays a removed line; a hunk never contains a line
// starting "diff ", so the next file's header cannot be mistaken for one.
export const diffLines = (diff) => {
  if (!diff) return [];
  let inHeader = true; // a bare unified diff has no "diff --git" line
  let markers = 1;
  return String(diff).replace(/\n$/, '').split('\n').map((text) => {
    if (DIFF_FILE_START.test(text)) {
      inHeader = true;
      return { text, kind: 'meta' };
    }
    if (text === DIFF_TRUNCATED) return { text, kind: 'meta' };
    if (text.startsWith('@@')) {
      inHeader = false;
      markers = Math.max(1, text.match(/^@+/)[0].length - 1);
      return { text, kind: 'hunk' };
    }
    if (inHeader) return { text, kind: 'meta' };
    const columns = text.slice(0, markers);
    if (columns.includes('+')) return { text, kind: 'add' };
    if (columns.includes('-')) return { text, kind: 'del' };
    return { text, kind: 'context' };
  });
};

// "2 files changed · +14 −3".
export const diffStats = (diff) => {
  const lines = diffLines(diff);
  const files = lines.filter((line) => line.kind === 'meta' && DIFF_FILE_START.test(line.text)).length;
  const added = lines.filter((line) => line.kind === 'add').length;
  const removed = lines.filter((line) => line.kind === 'del').length;
  return `${plural(files, 'file')} changed · +${added} −${removed}`;
};

// --- The model a session runs on ------------------------------------------
//
// The composer's model select. "default" sends no model, so Claude Code
// picks its own; the aliases are the ones its --model takes; "other" takes
// a full model id typed in. The server checks the same pattern
// (CodeSessionsController::MODEL_NAME), since the name becomes a CLI
// argument; checking it here too says what is wrong before a round trip.

export const DEFAULT_MODEL_CHOICE = 'default';
export const OTHER_MODEL_CHOICE = 'other';
export const CLAUDE_CODE_MODEL_ALIASES = ['sonnet', 'opus', 'haiku'];
export const CLAUDE_CODE_MODEL_NAME = /^[A-Za-z0-9][A-Za-z0-9._:[\]-]{0,99}$/;
// Where the last choice is remembered, per browser.
export const MODEL_CHOICE_STORAGE_KEY = 'actionagent.claudeCode.modelChoice';

export const modelOptions = () => [
  { value: DEFAULT_MODEL_CHOICE, label: "Default (Claude Code's own)" },
  ...CLAUDE_CODE_MODEL_ALIASES.map((alias) => ({ value: alias, label: alias })),
  { value: OTHER_MODEL_CHOICE, label: 'Other…' },
];

const isKnownChoice = (choice) => choice === DEFAULT_MODEL_CHOICE || choice === OTHER_MODEL_CHOICE
  || CLAUDE_CODE_MODEL_ALIASES.includes(choice);

// What a choice sends: { model } (null for Claude Code's default), or
// { error } when "Other…" holds nothing usable.
export const modelForRequest = (choice, custom = '') => {
  if (!isKnownChoice(choice) || choice === DEFAULT_MODEL_CHOICE) return { model: null };
  if (choice !== OTHER_MODEL_CHOICE) return { model: choice };

  const model = String(custom ?? '').trim();
  if (!model) return { error: 'Enter a model id, or pick one of the options.' };
  if (!CLAUDE_CODE_MODEL_NAME.test(model)) {
    return { error: `"${truncate(model, 40)}" is not a Claude Code model name (letters, digits and . _ : [ ] -).` };
  }
  return { model };
};

// The request body for a new session.
export const codeSessionRequestBody = (prompt, choice, custom) => {
  const { model } = modelForRequest(choice, custom);
  return model ? { prompt, model } : { prompt };
};

// The remembered choice, from what localStorage held (a string, or null);
// anything unreadable falls back to the default.
export const parseModelChoice = (raw) => {
  const fallback = { choice: DEFAULT_MODEL_CHOICE, custom: '' };
  if (typeof raw !== 'string' || !raw) return fallback;
  try {
    const value = JSON.parse(raw);
    if (!isObject(value) || !isKnownChoice(value.choice)) return fallback;
    const custom = typeof value.custom === 'string' ? value.custom.slice(0, 100) : '';
    return { choice: value.choice, custom };
  } catch (_error) {
    return fallback;
  }
};

export const serializeModelChoice = (choice, custom = '') => JSON.stringify({
  choice: isKnownChoice(choice) ? choice : DEFAULT_MODEL_CHOICE,
  custom: String(custom ?? '').slice(0, 100),
});

// How a session's model reads in the list and the detail.
export const sessionModelLabel = (session) => session?.model || 'default model';

// --- How Claude Code authenticates ------------------------------------------
//
// GET /api/sandboxes says how this install runs Claude Code
// (ActionAgent.claude_code_auth) and whether the caller's is usable:
//
//   claude_code_auth       "api_key" | "local_login"
//   claude_code_connected  true when sessions can run
//   claude_code_login      { logged_in, auth_method } — local_login only
//
// "api_key" runs sessions on an Anthropic API key the owner connects here.
// "local_login" runs them on the dashboard machine's own Claude Code login
// (`claude /login`), which the dashboard never sees. A Claude subscription
// token (`claude setup-token`) is never accepted: Anthropic does not let
// third-party apps hold Claude.ai credentials. One an earlier version stored
// comes back from /api/provider_keys as needs_replacing.

export const CLAUDE_CODE_API_KEY = 'api_key';
export const CLAUDE_CODE_LOCAL_LOGIN = 'local_login';
export const CLAUDE_CODE_LOGIN_COMMAND = 'claude /login';
export const CLAUDE_CODE_API_KEY_PLACEHOLDER = 'sk-ant-api03-…';
export const CLAUDE_CONSOLE_URL = 'https://platform.claude.com';
export const CLAUDE_CODE_POLICY_URL = 'https://code.claude.com/docs/en/legal-and-compliance.md';

// The sandbox listing's Claude Code fields, read defensively: anything but
// "local_login" is the API-key mode, and only a literal true counts.
export const claudeCodeAuth = (data) => {
  const login = isObject(data?.claude_code_login) ? data.claude_code_login : {};
  const localLogin = data?.claude_code_auth === CLAUDE_CODE_LOCAL_LOGIN;
  return {
    mode: localLogin ? CLAUDE_CODE_LOCAL_LOGIN : CLAUDE_CODE_API_KEY,
    connected: data?.claude_code_connected === true,
    loggedIn: localLogin && login.logged_in === true,
    authMethod: localLogin && typeof login.auth_method === 'string' && login.auth_method ? login.auth_method : null,
  };
};

// What the Claude Code card shows, from the listing's fields (claudeCodeAuth)
// and the stored key's row from /api/provider_keys (null while either
// loads).
//
//   view         "loading" | "local_login" | "api_key"
//   status       the line under the card's title
//   tone         "success" | "error" | "neutral"
//   keyForm      whether the card offers to connect, update or remove a key
//   needsReplacing  a stored subscription token that must become an API key
//   loginHint    the command to run on this machine, when logged out
export const claudeCodeCardState = (auth, keyRow) => {
  if (!auth) return { view: 'loading', status: 'Loading…', tone: 'neutral', keyForm: false, needsReplacing: false, loginHint: null };

  if (auth.mode === CLAUDE_CODE_LOCAL_LOGIN) {
    const how = auth.authMethod ? ` (${auth.authMethod})` : '';
    return {
      view: CLAUDE_CODE_LOCAL_LOGIN,
      status: auth.loggedIn ? `Using this machine's Claude Code login · logged in${how}` : "Using this machine's Claude Code login · not logged in",
      tone: auth.loggedIn ? 'success' : 'error',
      keyForm: false,
      needsReplacing: false,
      loginHint: auth.loggedIn ? null : CLAUDE_CODE_LOGIN_COMMAND,
    };
  }

  if (!keyRow) return { view: 'loading', status: 'Loading…', tone: 'neutral', keyForm: false, needsReplacing: false, loginHint: null };
  if (keyRow.configured && keyRow.needs_replacing === true) {
    return {
      view: CLAUDE_CODE_API_KEY,
      status: 'Needs an API key: the stored subscription token is no longer used',
      tone: 'error',
      keyForm: true,
      needsReplacing: true,
      loginHint: null,
    };
  }
  return {
    view: CLAUDE_CODE_API_KEY,
    status: keyRow.configured ? `Connected (${keyRow.hint})` : 'Not connected',
    tone: keyRow.configured ? 'success' : 'neutral',
    keyForm: true,
    needsReplacing: false,
    loginHint: null,
  };
};

// Why the session panel's composer is locked for want of Claude Code, or
// null when it can run. `loginHint` is the command to show beside the text.
// Nothing known yet reads as not connected: the server refuses then anyway.
export const claudeCodeNotConnectedHint = (auth) => {
  if (auth?.connected === true) return null;
  if (auth?.mode === CLAUDE_CODE_LOCAL_LOGIN) {
    return { text: 'Claude Code is not logged in on this machine. Run', loginHint: CLAUDE_CODE_LOGIN_COMMAND, after: 'as the user the dashboard runs as.' };
  }
  return { text: 'Connect an Anthropic API key under Claude Code below to run sessions in this checkout.', loginHint: null, after: null };
};
