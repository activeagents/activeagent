import assert from 'node:assert/strict';
import test from 'node:test';
import {
  ANSWER_FIELD,
  LIST_LIMIT,
  actorLabel,
  answerBlocks,
  answerControl,
  answerFromUiAction,
  askedLabel,
  choiceOptions,
  confirmArguments,
  expiryLabel,
  inputRequestsPath,
  isSettled,
  pendingBadge,
  pendingRequests,
  runIdFromSearch,
  runPath,
  runPollState,
  settleInputRequest,
  settleOutcome,
  settledLabel,
} from '../utils/inputRequests.mjs';

const now = Date.parse('2026-01-05T12:00:00Z');

const request = (overrides = {}) => ({
  id: 7,
  kind: 'text',
  status: 'pending',
  prompt: 'Which account should I refund?',
  options: null,
  tool_name: 'ask_user',
  arguments: null,
  agent: { id: 5, name: 'SupportBot', slug: 'support-bot' },
  run_id: 42,
  actor: { type: 'User', id: 3, name: 'Dana' },
  created_at: '2026-01-05T11:58:00Z',
  expires_at: '2026-01-06T11:00:00Z',
  ...overrides,
});

// A fetch stand-in that records the request and answers with one response.
function fakeFetch(status, body) {
  const calls = [];
  const impl = async (path, init) => {
    calls.push({ path, init });
    return { status, json: async () => body };
  };
  return { impl, calls };
}

test('the list path filters to an agent or a run only when given one', () => {
  assert.equal(inputRequestsPath(), '/api/input_requests');
  assert.equal(inputRequestsPath({ agentId: 5 }), '/api/input_requests?agent_id=5');
  assert.equal(inputRequestsPath({ runId: 42 }), '/api/input_requests?run_id=42');
});

test('the badge counts pending requests and hides when there are none', () => {
  assert.equal(pendingBadge(null), undefined);
  assert.equal(pendingBadge([]), undefined);
  assert.equal(pendingBadge([request({ status: 'answered' })]), undefined);
  assert.equal(pendingBadge([request(), request({ id: 8 }), request({ id: 9, status: 'expired' })]), 2);
  // The API lists at most LIST_LIMIT, so a full page may be the tip of more.
  assert.equal(pendingBadge(Array.from({ length: LIST_LIMIT }, (_, id) => request({ id }))), '99+');
});

test('pendingRequests drops settled and malformed entries', () => {
  assert.deepEqual(pendingRequests([request(), null, request({ id: 8, status: 'declined' })]).map((r) => r.id), [7]);
  assert.deepEqual(pendingRequests(undefined), []);
});

test('the runner keeps polling a run in flight and stops on one waiting for an answer', () => {
  assert.equal(runPollState({ status: 'pending' }), 'poll');
  assert.equal(runPollState({ status: 'running' }), 'poll');
  assert.equal(runPollState({ status: 'awaiting_input', input_requests: [request()] }), 'awaiting');
  // Every request of the pause settled: the resume job has the run next.
  assert.equal(runPollState({ status: 'awaiting_input', input_requests: [] }), 'poll');
  assert.equal(runPollState({ status: 'awaiting_input' }), 'poll');
  assert.equal(runPollState({ status: 'complete' }), 'finished');
  assert.equal(runPollState({ status: 'failed' }), 'finished');
  assert.equal(runPollState({ status: 'cancelled' }), 'finished');
  assert.equal(runPollState(null), 'finished');
});

test('each kind gets its own control, and an unknown kind gets none', () => {
  assert.equal(answerControl(request()), 'text');
  assert.equal(answerControl(request({ kind: 'choice' })), 'choice');
  assert.equal(answerControl(request({ kind: 'confirm' })), 'confirm');
  assert.equal(answerControl(request({ kind: 'secret' })), 'secret');
  assert.equal(answerControl(request({ kind: 'takeover' })), null);
});

test('choice options read strings and hashes, the value falling back to the label', () => {
  assert.deepEqual(choiceOptions(request({ options: ['Refund', 'Credit'] })), [
    { value: 'Refund', label: 'Refund' },
    { value: 'Credit', label: 'Credit' },
  ]);
  assert.deepEqual(choiceOptions(request({ options: [{ label: 'Full refund', value: 'full' }, { label: 'Store credit' }, {}, null] })), [
    { value: 'full', label: 'Full refund' },
    { value: 'Store credit', label: 'Store credit' },
  ]);
  assert.deepEqual(choiceOptions(request()), []);
});

test('text and choice requests are answered through Generative UI blocks; confirm and secret are not', () => {
  const [form] = answerBlocks(request());
  assert.equal(form.type, 'form');
  assert.deepEqual(form.fields.map((field) => [field.name, field.required]), [[ANSWER_FIELD, true]]);

  assert.deepEqual(answerBlocks(request({ kind: 'choice', options: [{ label: 'Full refund', value: 'full' }, 'Credit'] })), [
    { type: 'choices', options: ['Full refund', 'Credit'] },
  ]);
  assert.deepEqual(answerBlocks(request({ kind: 'confirm' })), []);
  assert.deepEqual(answerBlocks(request({ kind: 'secret' })), []);
});

test('a form submission answers with its field and a choice with the picked option value', () => {
  assert.equal(answerFromUiAction(request(), { kind: 'form', text: 'Answer: x', values: { [ANSWER_FIELD]: 'acct-9' } }), 'acct-9');
  const choice = request({ kind: 'choice', options: [{ label: 'Full refund', value: 'full' }, 'Credit'] });
  assert.equal(answerFromUiAction(choice, { kind: 'choice', text: 'Full refund' }), 'full');
  assert.equal(answerFromUiAction(choice, { kind: 'choice', text: 'Credit' }), 'Credit');
  assert.equal(answerFromUiAction(choice, { kind: 'choice', text: 'Something else' }), undefined);
  assert.equal(answerFromUiAction(request(), null), undefined);
});

test('a 409 reads as already answered, declined, expired or cancelled', () => {
  assert.deepEqual(settleOutcome(409, { status: 'answered' }), { state: 'closed', status: 'answered', message: 'Already answered' });
  assert.equal(settleOutcome(409, { status: 'declined' }).message, 'Already declined');
  assert.equal(settleOutcome(409, { status: 'expired' }).message, 'Expired before it was answered');
  assert.equal(settleOutcome(409, { status: 'cancelled' }).message, 'Cancelled: the run ended');
  assert.equal(settleOutcome(409, {}).message, 'No longer waiting for an answer');
});

test('success, a validation failure and other errors each read their own way', () => {
  assert.deepEqual(settleOutcome(200, { input_request: { status: 'answered' } }), { state: 'answered' });
  assert.deepEqual(settleOutcome(200, { input_request: { status: 'declined' } }), { state: 'declined' });
  assert.deepEqual(settleOutcome(422, { error: '"x" is not one of the options' }), { state: 'invalid', message: '"x" is not one of the options' });
  assert.deepEqual(settleOutcome(403, { error: 'You do not have permission to do this' }), { state: 'error', message: 'You do not have permission to do this' });
  assert.deepEqual(settleOutcome(404, {}), { state: 'error', message: 'This request is no longer available' });
  assert.deepEqual(settleOutcome(500, null), { state: 'error', message: 'Request failed (500)' });
});

test('only answered, declined and closed outcomes retire the control', () => {
  assert.equal(isSettled({ state: 'answered' }), true);
  assert.equal(isSettled({ state: 'declined' }), true);
  assert.equal(isSettled({ state: 'closed' }), true);
  assert.equal(isSettled({ state: 'invalid' }), false);
  assert.equal(isSettled({ state: 'error' }), false);
  assert.equal(isSettled(null), false);
});

test('an answer posts to the answer endpoint with the answer as JSON', async () => {
  const { impl, calls } = fakeFetch(200, { input_request: { status: 'answered' } });
  const outcome = await settleInputRequest(request(), { answer: 'acct-9' }, impl);

  assert.deepEqual(outcome, { state: 'answered' });
  assert.equal(calls[0].path, '/api/input_requests/7/answer');
  assert.equal(calls[0].init.method, 'POST');
  assert.deepEqual(JSON.parse(calls[0].init.body), { answer: 'acct-9' });
});

test('an approval sends true, and a decline posts to the decline endpoint without an answer', async () => {
  const approve = fakeFetch(200, { input_request: { status: 'answered' } });
  await settleInputRequest(request({ kind: 'confirm' }), { answer: true }, approve.impl);
  assert.deepEqual(JSON.parse(approve.calls[0].init.body), { answer: true });

  const decline = fakeFetch(200, { input_request: { status: 'declined' } });
  const outcome = await settleInputRequest(request({ kind: 'confirm' }), { decline: true }, decline.impl);
  assert.deepEqual(outcome, { state: 'declined' });
  assert.equal(decline.calls[0].path, '/api/input_requests/7/decline');
  assert.deepEqual(JSON.parse(decline.calls[0].init.body), {});
});

test('a conflict, an unreadable body and a network failure each come back as outcomes', async () => {
  assert.deepEqual(await settleInputRequest(request(), { answer: 'x' }, fakeFetch(409, { status: 'expired' }).impl), {
    state: 'closed', status: 'expired', message: 'Expired before it was answered',
  });

  const unreadable = async () => ({ status: 502, json: async () => { throw new SyntaxError('not json'); } });
  assert.deepEqual(await settleInputRequest(request(), { answer: 'x' }, unreadable), { state: 'error', message: 'Request failed (502)' });

  const offline = async () => { throw new TypeError('Failed to fetch'); };
  assert.equal((await settleInputRequest(request(), { answer: 'x' }, offline)).state, 'error');
});

test('a settled card says what happened, in terms of the request kind', () => {
  assert.equal(settledLabel(request(), { state: 'answered' }), 'Answered: the run continues');
  assert.equal(settledLabel(request({ kind: 'confirm' }), { state: 'answered' }), 'Approved: the tool runs');
  assert.equal(settledLabel(request({ kind: 'confirm' }), { state: 'declined' }), 'Declined: the tool does not run');
  assert.equal(settledLabel(request(), { state: 'declined' }), 'Declined');
  assert.equal(settledLabel(request(), { state: 'closed', message: 'Already answered' }), 'Already answered');
  assert.equal(settledLabel(request(), { state: 'invalid', message: 'x' }), null);
});

test('who is asking: the actor by name, else by type and id', () => {
  assert.equal(actorLabel({ type: 'User', id: 3, name: 'Dana' }), 'Dana');
  assert.equal(actorLabel({ type: 'User', id: 3, name: null }), 'User #3');
  assert.equal(actorLabel({ id: 3 }), 'user #3');
  assert.equal(actorLabel(null), null);
});

test('expiry and age read relative to now', () => {
  assert.equal(expiryLabel('2026-01-05T12:40:00Z', now), 'expires in 40m');
  assert.equal(expiryLabel('2026-01-05T12:00:20Z', now), 'expires in 1m');
  assert.equal(expiryLabel('2026-01-06T11:00:00Z', now), 'expires in 23h');
  assert.equal(expiryLabel('2026-01-09T12:00:00Z', now), 'expires in 4d');
  assert.equal(expiryLabel('2026-01-05T11:59:00Z', now), 'expired');
  assert.equal(expiryLabel(null, now), null);
  assert.equal(expiryLabel('not a date', now), null);
  assert.equal(askedLabel('2026-01-05T11:58:00Z', now), 'asked 2m ago');
  assert.equal(askedLabel(null, now), null);
});

test('a confirm request shows its call arguments as indented JSON', () => {
  assert.equal(confirmArguments(request({ kind: 'confirm', arguments: { invoice: 'INV-1', amount: 40 } })), '{\n  "invoice": "INV-1",\n  "amount": 40\n}');
  assert.equal(confirmArguments(request({ kind: 'confirm', arguments: {} })), null);
  assert.equal(confirmArguments(request()), null);
});

test('a request links to the runner opened on its run, and the runner reads the run back', () => {
  assert.equal(runPath(request()), '/agents/5/run?run=42');
  assert.equal(runPath(request({ agent: null })), null);
  assert.equal(runPath(request({ run_id: null })), null);
  assert.equal(runIdFromSearch('?run=42'), 42);
  assert.equal(runIdFromSearch('?tab=x&run=42'), 42);
  assert.equal(runIdFromSearch('?run=42abc'), null);
  assert.equal(runIdFromSearch(''), null);
});
