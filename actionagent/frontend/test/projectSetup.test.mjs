import assert from 'node:assert/strict';
import test from 'node:test';
import {
  answerBody,
  answerProblem,
  canAskSetup,
  installPatchPath,
  installPollDelay,
  installPullRequestActions,
  installPullRequestStatus,
  requestOptions,
  schemaToolsChanged,
  schemaToolsPayload,
  selectionFromChoices,
  setupInProgress,
  setupStatusText,
  toggleColumn,
  waitingLabel,
} from '../utils/projectSetup.mjs';

test('the boot status reads Waiting for you only while something waits', () => {
  assert.equal(waitingLabel(2), 'Waiting for you: 2');
  assert.equal(waitingLabel(0), null);
  assert.equal(waitingLabel(undefined), null);
});

test('an answer is checked the way the input requests API checks it', () => {
  assert.equal(answerProblem({ kind: 'text' }, '  '), 'Type an answer.');
  assert.equal(answerProblem({ kind: 'secret' }, 'short'), 'A secret is at least 8 characters.');
  assert.equal(answerProblem({ kind: 'secret' }, 'long enough'), null);
  assert.equal(answerProblem({ kind: 'choice', options: ['a', { value: 'b', label: 'Bee' }] }, 'c'), 'Choose one of the answers.');
  assert.equal(answerProblem({ kind: 'choice', options: ['a', { value: 'b', label: 'Bee' }] }, 'b'), null);
  assert.equal(answerProblem({ kind: 'confirm' }, ''), null);
  assert.deepEqual(requestOptions({ options: ['a', { value: 'b', label: 'Bee' }] }), [{ value: 'a', label: 'a' }, { value: 'b', label: 'Bee' }]);
});

test('a confirm request is answered true or false, the rest with their text', () => {
  assert.deepEqual(answerBody({ kind: 'confirm' }, true), { answer: true });
  assert.deepEqual(answerBody({ kind: 'confirm' }, 'yes'), { answer: false });
  assert.deepEqual(answerBody({ kind: 'secret' }, 'sk_test_value'), { answer: 'sk_test_value' });
});

test('the setup assistant is offered on a failed boot when it is available and idle', () => {
  const setup = { available: true, auto: true, last_run: null };
  assert.equal(canAskSetup({ sandbox_state: 'failed', setup }), true);
  assert.equal(canAskSetup({ sandbox_state: 'ready', setup }), false);
  assert.equal(canAskSetup({ sandbox_state: 'failed', setup: { ...setup, available: false } }), false);
  assert.equal(canAskSetup({ sandbox_state: 'failed', setup: { ...setup, last_run: { status: 'awaiting_input' } } }), false);
  assert.equal(canAskSetup({ sandbox_state: 'failed', setup: { ...setup, last_run: { status: 'complete' } } }), true);
});

test('the setup card says why the assistant cannot run, or what it did last', () => {
  assert.equal(setupStatusText({ available: false, reason: 'No provider key' }), 'No provider key');
  assert.equal(setupStatusText({ available: true, last_run: { status: 'awaiting_input' } }), 'The setup assistant is waiting for you.');
  assert.match(setupStatusText({ available: true, auto: false }), /only when you ask/);
  assert.equal(setupInProgress({ setup: { last_run: { status: 'running' } } }), true);
  assert.equal(setupInProgress({ pending_input_requests: 1, setup: {} }), true);
  assert.equal(setupInProgress({ pending_input_requests: 0, setup: { last_run: { status: 'complete' } } }), false);
});

test('choosing columns builds the schema tools list in the models\' order, and drops a model left empty', () => {
  const models = [
    { name: 'Reservation', columns: [{ name: 'status' }, { name: 'starts_at' }] },
    { name: 'Guest', columns: [{ name: 'name' }] },
  ];
  let selection = selectionFromChoices([{ model: 'Guest', filterable: [], returns: ['name'] }]);
  selection = toggleColumn(selection, 'Reservation', 'returns', 'starts_at');
  selection = toggleColumn(selection, 'Reservation', 'returns', 'status');
  selection = toggleColumn(selection, 'Reservation', 'filterable', 'status');

  assert.deepEqual(schemaToolsPayload(selection, models), [
    { model: 'Reservation', filterable: ['status'], returns: ['status', 'starts_at'] },
    { model: 'Guest', filterable: [], returns: ['name'] },
  ]);
  assert.equal(schemaToolsChanged(selection, [{ model: 'Guest', filterable: [], returns: ['name'] }], models), true);

  selection = toggleColumn(selection, 'Guest', 'returns', 'name');
  assert.deepEqual(Object.keys(selection), ['Reservation']);
  assert.equal(schemaToolsChanged(selection, schemaToolsPayload(selection, models), models), false);
});

test('the install pull request reads as published, open, merged or failed, and is polled while it can change', () => {
  assert.deepEqual(installPullRequestStatus(null), { label: 'not opened', tone: 'muted' });
  assert.equal(installPullRequestStatus({ status: 'publishing' }).label, 'publishing…');
  assert.equal(installPullRequestStatus({ status: 'published', number: 3, state: 'open', draft: true }).label, 'draft open');
  assert.equal(installPullRequestStatus({ status: 'published', number: 3, state: 'merged' }).label, 'merged');
  assert.equal(installPollDelay({ status: 'queued' }), 2000);
  assert.equal(installPollDelay({ status: 'published', number: 3, state: 'open' }), 60000);
  assert.equal(installPollDelay({ status: 'published', number: 3, state: 'merged' }), null);
  assert.equal(installPollDelay(null), null);
});

test('an install pull request is opened when there is none, and updated while it is open', () => {
  assert.deepEqual(installPullRequestActions(null), { canOpen: true, canUpdate: false });
  assert.deepEqual(installPullRequestActions({ status: 'published', number: 3, state: 'open' }), { canOpen: false, canUpdate: true });
  assert.deepEqual(installPullRequestActions({ status: 'publishing', number: 3, state: 'open' }), { canOpen: false, canUpdate: false });
  assert.deepEqual(installPullRequestActions({ status: 'failed' }), { canOpen: true, canUpdate: false });
  assert.deepEqual(installPullRequestActions({ status: 'published', number: 3, state: 'closed' }), { canOpen: true, canUpdate: false });
});

test('the install patch path names each chosen file', () => {
  assert.equal(installPatchPath(7, ['Gemfile', 'db/schema.rb'], 'Install'),
    '/api/projects/7/install_pull_request/patch?paths%5B%5D=Gemfile&paths%5B%5D=db%2Fschema.rb&title=Install');
  assert.equal(installPatchPath(7), '/api/projects/7/install_pull_request/patch');
});
