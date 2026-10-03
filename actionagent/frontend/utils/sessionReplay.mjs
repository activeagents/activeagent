// Session Replay: what the view does with the recordings list, and how it
// gathers a recording's actions. Pure apart from the fetch it is handed, so
// the node tests can pin it.

// The most actions GET /api/session_recordings/:id/actions returns per request.
export const ACTIONS_PAGE_SIZE = 500;

// Requests one replay may make for its actions, so a replay holds at most
// 5,000. The view renders every action it holds on each playback step.
export const MAX_ACTION_PAGES = 10;

export const LIST_LOAD_ERROR = 'Failed to load recordings';

const listFrom = (data) => (Array.isArray(data?.recordings) ? data.recordings : []);

// Returns what the view does once its recordings list request settles:
//   recordings   the picker's options
//   selectId     the recording to open, or null to keep the current selection
//   stopLoading  true when no recording load follows, so the view leaves its
//                loading state for the empty or error state
//   error        the message to show, or null
// `ok` is false both for a non-OK response and for a request that threw.
// When a recording is already selected, loading that recording owns the
// loading state, so a failed list only leaves the picker empty.
export function listLoadOutcome({ ok, data = null, selectedId = null }) {
  const recordings = ok ? listFrom(data) : [];

  if (selectedId != null) {
    return { recordings, selectId: null, stopLoading: false, error: null };
  }
  if (!ok) {
    return { recordings, selectId: null, stopLoading: true, error: LIST_LOAD_ERROR };
  }
  if (recordings.length === 0) {
    return { recordings, selectId: null, stopLoading: true, error: null };
  }
  return { recordings, selectId: recordings[0].id, stopLoading: false, error: null };
}

// Returns the action with `action_type` set. A show timeline from a server
// that keyed the action as `type` reads like an /actions entry.
export function normalizeAction(action) {
  if (!action || action.action_type != null) return action;
  return { ...action, action_type: action.type };
}

// The /actions path for one page: `/api/session_recordings/7/actions?limit=500`,
// then `...&after_sequence=500` for the page after sequence 500.
export function actionsPagePath(recordingId, afterSequence = null, limit = ACTIONS_PAGE_SIZE) {
  const query = new URLSearchParams({ limit: String(limit) });
  if (afterSequence != null) query.set('after_sequence', String(afterSequence));
  return `/api/session_recordings/${encodeURIComponent(recordingId)}/actions?${query}`;
}

async function fetchPage(fetchImpl, path) {
  try {
    const response = await fetchImpl(path);
    if (!response.ok) return null;
    return await response.json();
  } catch (_error) {
    return null;
  }
}

// Returns a recording's actions, following `after_sequence` page by page until
// the server reports no more, as { actions, total, complete }. `total` is the
// server's `total_actions`, or null when it sent none.
//
// Returns null when the first page fails, so the caller can fall back to the
// show response's timeline. After the first page, entries whose sequence is
// not past the cursor are dropped, so a server that ignores `after_sequence`
// or overlaps its pages cannot repeat an action. A later page that fails, a
// page with nothing past the cursor, or reaching `maxPages` ends the walk with
// `complete: false` and the actions gathered so far.
export async function fetchAllActions(recordingId, {
  fetchImpl = (...args) => globalThis.fetch(...args),
  pageSize = ACTIONS_PAGE_SIZE,
  maxPages = MAX_ACTION_PAGES,
} = {}) {
  const actions = [];
  let total = null;
  let afterSequence = null;

  for (let page = 0; page < maxPages; page += 1) {
    const data = await fetchPage(fetchImpl, actionsPagePath(recordingId, afterSequence, pageSize));
    if (!data) return page === 0 ? null : { actions, total, complete: false };

    const batch = Array.isArray(data.actions) ? data.actions.map(normalizeAction) : [];
    const fresh = afterSequence == null ? batch : batch.filter((action) => action?.sequence > afterSequence);
    actions.push(...fresh);
    if (Number.isFinite(data.total_actions)) total = data.total_actions;
    if (!data.has_more || batch.length === 0) return { actions, total, complete: true };

    const lastSequence = fresh[fresh.length - 1]?.sequence;
    if (!Number.isFinite(lastSequence)) return { actions, total, complete: false };
    afterSequence = lastSequence;
  }

  return { actions, total, complete: false };
}

// The count beside the actions list: "120", or "5000 of 12500" when the
// replay holds only part of the recording.
export function actionCountLabel(loaded, total, complete) {
  if (complete || total == null || total <= loaded) return String(loaded);
  return `${loaded} of ${total}`;
}
