import assert from 'node:assert/strict';
import test from 'node:test';

import {
  environmentSecrets,
  explorerBudget,
  explorerStartError,
  signInPayload,
  signInResult,
  stopReasonText,
} from '../utils/explorer.mjs';

// Starting the explorer and its sign-in step: the budget sent, what a
// refusal or a check says, and which secrets the Environment tab lists.

test('the budget sends what was entered, within the engine\'s limits', () => {
  assert.deepEqual(explorerBudget({ minutes: '10', steps: '', cost: ' 2.5 ' }), { budget: { minutes: 10, cost: 2.5 } });
  assert.deepEqual(explorerBudget({}), { budget: {} });
  assert.match(explorerBudget({ minutes: '0' }).error, /Minutes must be a whole number above 0/);
  assert.match(explorerBudget({ steps: '1.5' }).error, /whole number/);
  assert.match(explorerBudget({ steps: '5000' }).error, /at most 1000/);
  assert.match(explorerBudget({ cost: 'lots' }).error, /Cost cap must be a number/);
});

test('a refused start says why', () => {
  assert.equal(explorerStartError(402, { message: 'No explorations left this month' }), 'No explorations left this month');
  assert.equal(explorerStartError(402, {}), 'Your plan has no explorations left.');
  assert.match(explorerStartError(409, { code: 'sandbox_not_ready' }), /Boot the project first/);
  assert.match(explorerStartError(409, { code: 'exploration_running' }), /already walking/);
  assert.equal(explorerStartError(422, { code: 'browser_unavailable', error: 'Chromium is not installed' }), 'Chromium is not installed');
  assert.equal(explorerStartError(500), 'The exploration did not start (HTTP 500).');
});

test('a stop reason reads as words', () => {
  assert.equal(stopReasonText('budget_steps'), 'Its browser step budget ran out.');
  assert.match(stopReasonText('budget_context'), /conversation grew too long/);
  assert.equal(stopReasonText('custom'), 'custom');
  assert.equal(stopReasonText(null), null);
});

test('a sign-in check shows its message in a tone for its status', () => {
  assert.deepEqual(signInResult({ status: 'unsupported', message: 'not supported in the sandbox' }),
    { tone: 'warning', text: 'not supported in the sandbox' });
  assert.equal(signInResult({ status: 'signed_in', message: 'Signed in' }).tone, 'success');
  assert.equal(signInResult(null), null);
});

test('the credentials form sends its filled fields, keeping the password as typed', () => {
  assert.deepEqual(signInPayload({ login_url: ' /users/sign_in ', login: 'dev@example.com', password: ' pa ss ', submit_field: '' }),
    { payload: { login_url: '/users/sign_in', login: 'dev@example.com', password: ' pa ss ' } });
  assert.match(signInPayload({ login: 'dev@example.com' }).error, /password/);
  assert.deepEqual(signInPayload({ login: 'qa@example.com', password: '' }, { passwordSaved: true }),
    { payload: { login: 'qa@example.com' } });
  assert.match(signInPayload({ login_url: 'https://elsewhere.example', password: 'x' }).error, /path on the app/);
  assert.match(signInPayload({ login_url: '//elsewhere.example', password: 'x' }).error, /path on the app/);
});

test('the Environment tab lists env secrets only', () => {
  const secrets = [{ name: 'STRIPE_SECRET_KEY', kind: 'env' }, { name: 'APP_SIGN_IN', kind: 'sign_in' }, { name: 'LEGACY' }];
  assert.deepEqual(environmentSecrets(secrets).map((secret) => secret.name), ['STRIPE_SECRET_KEY', 'LEGACY']);
});
