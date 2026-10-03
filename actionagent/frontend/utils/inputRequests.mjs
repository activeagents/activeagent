// Input requests as the dashboard lists and answers them. A request is a
// question a paused run put to a person (ActionAgent::InputRequest), in the
// shape GET /api/input_requests returns:
//
//   { id, kind, status, prompt, options, tool_name, arguments,
//     agent: { id, name, slug }, run_id, actor: { type, id, name },
//     created_at, expires_at }
//
// It never carries the answer. `kind` is text, choice, confirm or secret.

import { dashboardViewPath } from './dashboardRoutes.mjs';
import { fmtAgo } from './toolRoster.mjs';

export const INPUT_REQUESTS_PATH = '/api/input_requests';

// The window event this tab dispatches after it settles a request or sees a
// run pause, so every count and list on the page refetches at once.
export const INPUT_REQUESTS_CHANGED = 'action-agent:input-requests-changed';

export const INPUT_REQUESTS_REFRESH_MS = 30000;

// The most requests the API lists in one response
// (InputRequestsController::LIST_LIMIT).
export const LIST_LIMIT = 100;


const KINDS = ['text', 'choice', 'confirm', 'secret'];

// The list path, filtered to one agent or run when given:
// `inputRequestsPath({ agentId: 5 })` → `'/api/input_requests?agent_id=5'`.
export function inputRequestsPath({ agentId = null, runId = null } = {}) {
  const query = new URLSearchParams();
  if (agentId != null) query.set('agent_id', String(agentId));
  if (runId != null) query.set('run_id', String(runId));
  const search = query.toString();
  return search ? `${INPUT_REQUESTS_PATH}?${search}` : INPUT_REQUESTS_PATH;
}

export function pendingRequests(requests) {
  return (Array.isArray(requests) ? requests : []).filter((request) => request && request.status === 'pending');
}

// The sidebar badge for a list of requests: the pending count, '99+' once the
// list is as long as the API returns, and undefined when nothing is pending
// or the list has not loaded, which hides the badge.
export function pendingBadge(requests) {
  const count = pendingRequests(requests).length;
  if (count === 0) return undefined;
  return count >= LIST_LIMIT ? `${LIST_LIMIT - 1}+` : count;
}

// What the runner does with a run it just read:
//   'poll'     pending or running, or paused with every request settled
//              while the resume is on its way
//   'awaiting' paused on a request nobody has answered yet
//   'finished' anything else
export function runPollState(run) {
  const status = run?.status;
  if (status === 'pending' || status === 'running') return 'poll';
  if (status === 'awaiting_input') return pendingRequests(run.input_requests).length > 0 ? 'awaiting' : 'poll';
  return 'finished';
}

// The control a request is answered with: its kind, or null for a kind this
// dashboard does not know, which can only be declined.
export function answerControl(request) {
  return KINDS.includes(request?.kind) ? request.kind : null;
}

// A `choice` request's options as `{ label, value }`. An option is a string,
// or a hash whose `value` (else its `label`) is what the answer must be,
// the way InputRequest#choice_values reads it.
export function choiceOptions(request) {
  return (Array.isArray(request?.options) ? request.options : [])
    .map((option) => {
      if (option && typeof option === 'object') {
        const value = String(option.value ?? option.label ?? '');
        return { value, label: String(option.label ?? value) };
      }
      return option == null ? null : { value: String(option), label: String(option) };
    })
    .filter((option) => option && option.value !== '');
}

// The form field a `text` request's answer is read from, named for the
// request because Generative UI derives a field's DOM id from its name, and
// two cards on one page must not share an id: `answerField({ id: 7 })` →
// `'answer-7'`.
export function answerField(request) {
  return request?.id == null ? 'answer' : `answer-${request.id}`;
}

// The Generative UI blocks a request is answered through: one required field
// for `text`, the option buttons for `choice`, none for the other kinds. A
// secret is never asked through these blocks.
export function answerBlocks(request) {
  switch (answerControl(request)) {
    case 'text':
      return [{ type: 'form', submit: 'Answer', fields: [{ name: answerField(request), label: 'Your answer', type: 'textarea', required: true }] }];
    case 'choice':
      return [{ type: 'choices', options: choiceOptions(request).map((option) => option.label) }];
    default:
      return [];
  }
}

// The answer a Generative UI action gives a request: the field's value for a
// submitted form, the picked option's value for a choice, and undefined for
// anything else.
export function answerFromUiAction(request, action) {
  if (action?.kind === 'form') {
    const value = action.values?.[answerField(request)];
    return value == null ? undefined : String(value);
  }
  if (action?.kind === 'choice') return choiceOptions(request).find((option) => option.label === action.text)?.value;
  return undefined;
}

const CLOSED_MESSAGES = {
  answered: 'Already answered',
  declined: 'Already declined',
  expired: 'Expired before it was answered',
  cancelled: 'Cancelled: the run ended',
};

// What an answer or a decline came to, from the endpoint's HTTP status and
// JSON body:
//   { state: 'answered' }          settled by this call ('declined' likewise)
//   { state: 'closed', status }    409: settled elsewhere, expired or cancelled
//   { state: 'invalid' }           422: the answer does not fit; send another
//   { state: 'error' }             anything else; the request may still wait
// Every outcome but the first two carries a `message` to show.
export function settleOutcome(httpStatus, body = {}) {
  if (httpStatus >= 200 && httpStatus < 300) {
    return { state: body?.input_request?.status === 'declined' ? 'declined' : 'answered' };
  }
  if (httpStatus === 409) {
    const status = body?.status || null;
    return { state: 'closed', status, message: CLOSED_MESSAGES[status] || 'No longer waiting for an answer' };
  }
  if (httpStatus === 422) return { state: 'invalid', message: body?.error || 'That answer does not fit this request' };
  if (httpStatus === 404) return { state: 'error', message: 'This request is no longer available' };
  return { state: 'error', message: body?.error || `Request failed (${httpStatus})` };
}

// Whether the request can no longer be answered from this card.
export function isSettled(outcome) {
  return ['answered', 'declined', 'closed'].includes(outcome?.state);
}

// Posts an answer, or a decline when `decline` is set, and returns the
// outcome (see settleOutcome). A `confirm` request is approved with
// `answer: true`. Never starts a run: the server resumes the paused one.
export async function settleInputRequest(request, { answer, decline = false } = {}, fetchImpl = globalThis.fetch) {
  const path = `${INPUT_REQUESTS_PATH}/${encodeURIComponent(request.id)}/${decline ? 'decline' : 'answer'}`;
  let response;
  try {
    response = await fetchImpl(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(decline ? {} : { answer }),
    });
  } catch {
    return { state: 'error', message: 'Could not reach the server. Try again.' };
  }
  const body = await response.json().catch(() => ({}));
  return settleOutcome(response.status, body);
}

// The line a settled card shows in place of its control.
export function settledLabel(request, outcome) {
  if (outcome?.state === 'closed') return outcome.message;
  if (outcome?.state === 'declined') return request?.kind === 'confirm' ? 'Declined: the tool does not run' : 'Declined';
  if (outcome?.state === 'answered') return request?.kind === 'confirm' ? 'Approved: the tool runs' : 'Answered: the run continues';
  return null;
}

// Who the paused run acts for, or null when it acts for nobody in
// particular.
export function actorLabel(actor) {
  if (!actor) return null;
  if (actor.name) return String(actor.name);
  return actor.id != null ? `${actor.type || 'user'} #${actor.id}` : null;
}

// 'expires in 40m', 'expires in 23h', 'expires in 3d', 'expired', or null for
// a request that waits indefinitely.
export function expiryLabel(expiresAt, now = Date.now()) {
  if (!expiresAt) return null;
  const at = new Date(expiresAt).getTime();
  if (Number.isNaN(at)) return null;
  const minutes = Math.floor((at - now) / 60000);
  if (minutes < 0) return 'expired';
  if (minutes < 60) return `expires in ${Math.max(minutes, 1)}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `expires in ${hours}h`;
  return `expires in ${Math.floor(hours / 24)}d`;
}

export function askedLabel(createdAt, now = Date.now()) {
  return createdAt ? `asked ${fmtAgo(createdAt, now)}` : null;
}

// The arguments of the call a `confirm` request holds, as indented JSON, or
// null when it has none.
export function confirmArguments(request) {
  const args = request?.arguments;
  if (args == null || (typeof args === 'object' && Object.keys(args).length === 0)) return null;
  return typeof args === 'string' ? args : JSON.stringify(args, null, 2);
}

// The mount-relative path of the runner opened on the request's run
// (`/agents/5/run?run=42`), or null when the request names no agent or run.
export function runPath(request) {
  const agentId = request?.agent?.id;
  const runId = request?.run_id;
  if (agentId == null || runId == null) return null;
  const path = dashboardViewPath('runner', { agent: { id: agentId } });
  return path ? `${path}?run=${encodeURIComponent(runId)}` : null;
}

// The run id a runner URL names (`?run=42`), or null.
export function runIdFromSearch(search = '') {
  const value = new URLSearchParams(search).get('run');
  return value && /^\d+$/.test(value) ? Number(value) : null;
}
