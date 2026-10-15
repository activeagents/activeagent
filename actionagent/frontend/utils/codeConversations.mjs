// Claude Code and Codex conversations as Interactions: a conversation is
// its first session (the root) and the turns that followed, listed as
// "code-<root id>" beside agent contexts and reported traces.

import { fmtCostUsd, fmtDurationMs, isCodeSessionActive, plural } from './codeSessions.mjs';

export const CONVERSATION_POLL_INTERVAL_MS = 1500;

// The source filter over Interactions: GET /api/interactions?source=.
export const INTERACTION_SOURCES = [
  { id: 'all', label: 'All' },
  { id: 'agent', label: 'Agent runs' },
  { id: 'claude_code', label: 'Claude Code' },
  { id: 'codex', label: 'Codex' },
];

const SOURCE_IDS = new Set(INTERACTION_SOURCES.map((source) => source.id));

// Whether an interaction row is a code conversation.
export const isCodeInteraction = (row) => row?.source === 'code_session' || /^code-\d+$/.test(String(row?.id ?? ''));

// The root session id of "code-<id>", or null.
export const codeRootId = (id) => {
  const match = /^code-(\d+)$/.exec(String(id ?? ''));
  return match ? Number(match[1]) : null;
};

// What an Interactions path under the mount asks for:
//   /interactions                          the list
//   /interactions/code-<id>                one conversation
//   /interactions/latest                   the newest conversation (of ?project=)
// plus ?source= and ?project= filters.
export const parseInteractionsLocation = (path, search = '') => {
  const params = new URLSearchParams(search);
  const source = SOURCE_IDS.has(params.get('source')) ? params.get('source') : 'all';
  const project = /^\d+$/.test(params.get('project') || '') ? Number(params.get('project')) : null;
  const rest = String(path || '').replace(/^\/interactions\/?/, '').replace(/\/$/, '');
  if (rest === 'latest') return { view: 'latest', source, project, codeId: null };
  const codeId = codeRootId(rest);
  if (codeId) return { view: 'conversation', source, project, codeId };
  return { view: 'list', source, project, codeId: null };
};

// The mount-relative path of a conversation, or of the list with filters.
export const conversationPath = (rootId) => `/interactions/code-${rootId}`;
export const interactionsListPath = ({ source = 'all', project = null } = {}) => {
  const params = new URLSearchParams();
  if (source && source !== 'all') params.set('source', source);
  if (project) params.set('project', String(project));
  const query = params.toString();
  return `/interactions${query ? `?${query}` : ''}`;
};

// The query string asking for the API's list with filters applied.
export const interactionsQuery = ({ minutes = null, agentId = null, source = 'all', project = null } = {}) => {
  const params = new URLSearchParams();
  if (minutes) params.set('minutes', String(minutes));
  if (agentId) params.set('agent_id', String(agentId));
  if (source && source !== 'all') params.set('source', source);
  if (project) params.set('project_id', String(project));
  return params.toString();
};

// The conversation to open as "latest": an active one first, then the most
// recently active.
export const latestConversation = (rows) => {
  const code = (rows || []).filter(isCodeInteraction);
  if (code.length === 0) return null;
  const byActivity = [...code].sort((a, b) => String(b.last_activity_at).localeCompare(String(a.last_activity_at)));
  return byActivity.find((row) => row.active) || byActivity[0];
};

// ?after[<turn id>]=<events seen>, so polling sends only new events.
export const afterQuery = (turns) => (turns || [])
  .filter((turn) => (turn.events || []).length > 0)
  .map((turn) => `after[${encodeURIComponent(turn.id)}]=${turn.events_offset + turn.events.length}`)
  .join('&');

// Merges a fresh detail into the conversation held, appending each turn's
// new events after those already held.
export const mergeConversation = (current, fresh) => {
  if (!fresh) return current;
  if (!current) return fresh;
  const held = new Map((current.turns || []).map((turn) => [turn.id, turn]));
  const turns = (fresh.turns || []).map((turn) => {
    const previous = held.get(turn.id);
    if (!previous || turn.events_offset === 0) return turn;
    const kept = (previous.events || []).slice(0, turn.events_offset - previous.events_offset);
    return { ...turn, events_offset: previous.events_offset, events: [...kept, ...(turn.events || [])] };
  });
  return { ...fresh, turns };
};

// Whether any turn is queued or running.
export const conversationActive = (conversation) => (conversation?.turns || []).some(isCodeSessionActive);

// "Turn 2 · $0.03 · 12s · 2 files +14 −3 since checkout".
export const turnLine = (turn) => {
  const parts = [`Turn ${Number(turn.turn_index) + 1}`];
  if (turn.total_cost_usd != null) parts.push(fmtCostUsd(turn.total_cost_usd));
  if (turn.duration_ms != null) parts.push(fmtDurationMs(turn.duration_ms));
  if (turn.diff_stat) {
    parts.push(`${plural(turn.diff_stat.files, 'file')} +${turn.diff_stat.additions} −${turn.diff_stat.deletions} since checkout`);
  }
  return parts.join(' · ');
};

// "3 turns · $0.12 · 41.2k tokens".
export const conversationLine = (conversation) => {
  const parts = [plural(conversation.turn_count ?? (conversation.turns || []).length, 'turn')];
  if (conversation.total_cost_usd) parts.push(fmtCostUsd(conversation.total_cost_usd));
  const tokens = conversation.tokens?.total || 0;
  if (tokens) parts.push(`${tokens >= 1000 ? `${(tokens / 1000).toFixed(1)}k` : tokens} tokens`);
  return parts.join(' · ');
};

// The latest request an agent made for a person, read from the transcript
// (the sidecar's browser_request_person tool), or null once a later turn
// was sent: the person answered it.
export const pendingPersonRequest = (conversation) => {
  const turns = conversation?.turns || [];
  const last = turns[turns.length - 1];
  if (!last || isCodeSessionActive(last)) return null;
  for (const event of [...(last.events || [])].reverse()) {
    const content = event?.message?.content;
    if (!Array.isArray(content)) continue;
    for (const block of [...content].reverse()) {
      if (block?.type === 'tool_use' && /(^|__)browser_request_person$/.test(String(block.name || ''))) {
        const reason = typeof block.input?.reason === 'string' ? block.input.reason : null;
        if (reason) return { reason, turn: last.turn_index };
      }
    }
  }
  return null;
};

// What the composer says it will do.
export const composerHint = (conversation, { handoff = null } = {}) => {
  if (conversation?.sandbox_status && conversation.sandbox_status !== 'ready') {
    return `The sandbox is ${conversation.sandbox_status}: boot it again to continue this conversation.`;
  }
  const waiting = (conversation?.turns || []).filter((turn) => turn.status === 'queued').length;
  const running = (conversation?.turns || []).some((turn) => turn.status === 'running');
  const note = handoff ? ' Claude Code will be told you drove the browser.' : '';
  if (running) return `Your message waits for the turn that runs${waiting ? ` (and ${plural(waiting, 'more')})` : ''}.${note}`;
  return `Sends the next turn, resuming this conversation.${note}`;
};

// Whether a conversation opens with its browser panel: an explicit
// ?browser=1 or ?browser=0 wins, then the person's last choice ("1"/"0"
// as stored), and hidden when there is neither.
export const showBrowserPreference = (search, stored) => {
  const param = new URLSearchParams(search || '').get('browser');
  if (param === '1' || param === '0') return param === '1';
  return stored === '1';
};

// The conversation panel's share of the width beside the browser, as a
// percentage: dragged or keyed between SPLIT_MIN and SPLIT_MAX, so neither
// panel gets too narrow to use.
export const SPLIT_DEFAULT = 50;
export const SPLIT_MIN = 25;
export const SPLIT_MAX = 75;
const SPLIT_STEP = 5;

export const clampSplit = (value) => {
  const number = Number(value);
  if (!Number.isFinite(number)) return SPLIT_DEFAULT;
  return Math.min(SPLIT_MAX, Math.max(SPLIT_MIN, Math.round(number * 10) / 10));
};

// Where the pointer is, as a share of the row it is dragging across.
export const splitFromPointer = (clientX, { left, width }) => (
  width > 0 ? clampSplit(((clientX - left) / width) * 100) : SPLIT_DEFAULT
);

// The split after a key on the separator, or null for a key it ignores.
export const splitForKey = (split, key) => {
  switch (key) {
    case 'ArrowLeft': return clampSplit(split - SPLIT_STEP);
    case 'ArrowRight': return clampSplit(split + SPLIT_STEP);
    case 'Home': return SPLIT_MIN;
    case 'End': return SPLIT_MAX;
    case 'Enter': return SPLIT_DEFAULT;
    default: return null;
  }
};
