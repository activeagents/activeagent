// Pure helpers for starting the engine's explorer on a project and for its
// sign-in step: the budget a start sends, what a refused start or a sign-in
// check says, and why a walk stopped.

// The explorer's limits, as ActionAgent::Exploration::DEFAULT_BUDGET and
// MAX_BUDGET set them.
export const EXPLORER_DEFAULT_BUDGET = { minutes: 15, steps: 150 };
export const EXPLORER_MAX_BUDGET = { minutes: 120, steps: 1000, cost: 100 };

const BUDGET_LABELS = { minutes: 'Minutes', steps: 'Browser steps', cost: 'Cost cap' };

// The budget a start sends, from the form's text fields ({ minutes, steps,
// cost }), as { budget } or { error }. An empty field is left out, so the
// engine's default applies; cost is optional.
export function explorerBudget(form = {}) {
  const budget = {};
  for (const key of ['minutes', 'steps', 'cost']) {
    const text = String(form[key] ?? '').trim();
    if (text === '') continue;

    const value = Number(text);
    const whole = key !== 'cost';
    if (!Number.isFinite(value) || value <= 0 || (whole && !Number.isInteger(value))) {
      return { error: `${BUDGET_LABELS[key]} must be a ${whole ? 'whole number' : 'number'} above 0.` };
    }
    if (value > EXPLORER_MAX_BUDGET[key]) return { error: `${BUDGET_LABELS[key]} may be at most ${EXPLORER_MAX_BUDGET[key]}.` };
    budget[key] = value;
  }
  return { budget };
}

const START_REFUSALS = {
  sandbox_not_ready: 'Boot the project first: the explorer walks the app its sandbox serves.',
  exploration_running: 'An exploration of this project is already walking the app. Stop it or wait for it to finish.',
  no_target: 'Choose the agent to evaluate first: the explorer proposes questions for that agent.',
  browser_unavailable: null,
};

// What a refused start says, from its HTTP status and JSON body.
export function explorerStartError(status, data = {}) {
  if (status === 402) return data.message || data.error || 'Your plan has no explorations left.';
  if (data.code && START_REFUSALS[data.code]) return START_REFUSALS[data.code];
  return data.error || `The exploration did not start (HTTP ${status}).`;
}

const STOP_REASONS = {
  finished: 'The explorer finished.',
  budget_minutes: 'Its time budget ran out.',
  budget_steps: 'Its browser step budget ran out.',
  budget_cost: 'Its cost budget ran out.',
  stopped: 'Stopped for review.',
  error: 'It failed.',
};

// Why a walk ended, in words, or the stored reason when it is not one the
// engine sets.
export function stopReasonText(reason) {
  if (!reason) return null;
  return STOP_REASONS[reason] || reason;
}

const SIGN_IN_TONES = { signed_in: 'success', failed: 'error', unsupported: 'warning', error: 'error' };

// A sign-in check's result as { tone, text }.
export function signInResult(result) {
  if (!result) return null;
  return { tone: SIGN_IN_TONES[result.status] || 'muted', text: result.message || result.status };
}

// The credentials form's request body, without empty fields, or { error }.
// The login URL must be a path on the app. With passwordSaved, an empty
// password is left out and the engine keeps the saved one.
export function signInPayload(form = {}, { passwordSaved = false } = {}) {
  const payload = {};
  for (const key of ['login_url', 'login', 'password', 'login_field', 'password_field', 'submit_field']) {
    const value = String(form[key] ?? '').trim();
    if (value) payload[key] = key === 'password' ? String(form[key]) : value;
  }
  if (!payload.password && !passwordSaved) return { error: 'Enter the test account\'s password.' };
  if (payload.login_url && (!payload.login_url.startsWith('/') || payload.login_url.startsWith('//'))) {
    return { error: 'The login URL must be a path on the app, such as /users/sign_in.' };
  }
  return { payload };
}

// The project's secrets the Environment tab lists: the env ones. Sign-in
// secrets have a panel of their own.
export function environmentSecrets(secrets = []) {
  return secrets.filter((secret) => !secret.kind || secret.kind === 'env');
}
