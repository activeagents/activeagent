// Pure helpers for a project's setup: the requests for input its agents wait
// on, the setup assistant, the models the App assistant may read, and the
// install pull request.

// The shortest secret the input requests API takes (InputRequest::SECRET_MIN_LENGTH).
export const SECRET_MIN_LENGTH = 8;
// How often the Project page reads an open install pull request again. The
// server asks GitHub at most once a minute (DraftPullRequest::STATUS_REFRESH_INTERVAL).
export const INSTALL_PR_POLL_INTERVAL_MS = 60000;
export const INSTALL_PR_PUBLISH_POLL_INTERVAL_MS = 2000;

// "Waiting for you: 2", or null when nothing waits.
export function waitingLabel(count) {
  const value = Number(count) || 0;
  return value > 0 ? `Waiting for you: ${value}` : null;
}

// The values a `choice` request may be answered with, as { value, label }.
export function requestOptions(request) {
  return (request?.options || []).map((option) => {
    if (option && typeof option === 'object') {
      const value = String(option.value ?? option.label ?? '');
      return { value, label: String(option.label ?? value) };
    }
    return { value: String(option), label: String(option) };
  });
}

// Why `value` cannot answer `request` yet, or null when it can. A confirm
// request is answered with its buttons, so it never has a problem.
export function answerProblem(request, value) {
  if (!request || request.kind === 'confirm') return null;
  const text = typeof value === 'string' ? value : '';
  if (!text.trim()) return request.kind === 'choice' ? 'Choose an answer.' : 'Type an answer.';
  if (request.kind === 'secret' && text.length < SECRET_MIN_LENGTH) {
    return `A secret is at least ${SECRET_MIN_LENGTH} characters.`;
  }
  if (request.kind === 'choice' && !requestOptions(request).some((option) => option.value === text)) {
    return 'Choose one of the answers.';
  }
  return null;
}

// The body POST /api/input_requests/:id/answer takes for `value`: true or
// false for a confirm request, the text otherwise.
export function answerBody(request, value) {
  if (request?.kind === 'confirm') return { answer: value === true };
  return { answer: value };
}

// What the setup card says about the setup assistant, from the project's
// `setup` summary.
export function setupStatusText(setup) {
  if (!setup) return null;
  if (!setup.available) return setup.reason || 'The setup assistant is not available.';
  if (setup.last_run) {
    const states = { awaiting_input: 'is waiting for you', running: 'is working', pending: 'is starting', complete: 'finished', failed: 'failed' };
    return `The setup assistant ${states[setup.last_run.status] || setup.last_run.status}.`;
  }
  return setup.auto
    ? 'When a boot fails, the setup assistant reads its logs and asks for what is missing.'
    : 'The setup assistant starts only when you ask for it.';
}

// Whether the project's setup assistant is at work or waiting on someone,
// so the Project page keeps reading the project.
export function setupInProgress(project) {
  return ['pending', 'running', 'awaiting_input'].includes(project?.setup?.last_run?.status)
    || (Number(project?.pending_input_requests) || 0) > 0;
}

// Whether "Ask the setup assistant" is offered: on a failed boot, when it
// is available and not already at work.
export function canAskSetup(project) {
  const setup = project?.setup;
  if (!setup?.available || project?.sandbox_state !== 'failed') return false;
  return !['pending', 'running', 'awaiting_input'].includes(setup.last_run?.status);
}

// The schema tool choices as { model => { filterable: Set, returns: Set } }.
export function selectionFromChoices(choices = []) {
  const selection = {};
  for (const choice of choices) {
    selection[choice.model] = { filterable: new Set(choice.filterable || []), returns: new Set(choice.returns || []) };
  }
  return selection;
}

// `selection` with `column` of `model` switched on or off for `option`
// ("filterable" or "returns"). A model left with no column is dropped.
export function toggleColumn(selection, model, option, column) {
  const current = selection[model] || { filterable: new Set(), returns: new Set() };
  const next = { filterable: new Set(current.filterable), returns: new Set(current.returns) };
  if (next[option].has(column)) next[option].delete(column); else next[option].add(column);
  const result = { ...selection, [model]: next };
  if (next.filterable.size === 0 && next.returns.size === 0) delete result[model];
  return result;
}

// The PUT /api/projects/:id/schema_tools list, in the order the models are
// listed, columns in the order the model lists them.
export function schemaToolsPayload(selection, models = []) {
  const order = new Map(models.map((model, index) => [model.name, index]));
  return Object.keys(selection)
    .sort((a, b) => (order.get(a) ?? Infinity) - (order.get(b) ?? Infinity) || a.localeCompare(b))
    .map((name) => {
      const columns = (models.find((model) => model.name === name)?.columns || []).map((column) => column.name);
      const ordered = (set) => [...set].sort((a, b) => (columns.indexOf(a) + 1 || Infinity) - (columns.indexOf(b) + 1 || Infinity));
      return { model: name, filterable: ordered(selection[name].filterable), returns: ordered(selection[name].returns) };
    });
}

// Whether `selection` differs from the `choices` stored on the project.
export function schemaToolsChanged(selection, choices = [], models = []) {
  const normalize = (list) => JSON.stringify(list.map((choice) => ({
    model: choice.model, filterable: [...(choice.filterable || [])].sort(), returns: [...(choice.returns || [])].sort(),
  })).sort((a, b) => a.model.localeCompare(b.model)));
  return normalize(schemaToolsPayload(selection, models)) !== normalize(choices);
}

// How the install pull request reads on the Project page: { label, tone }.
export function installPullRequestStatus(pullRequest) {
  if (!pullRequest) return { label: 'not opened', tone: 'muted' };
  if (pullRequest.status === 'queued' || pullRequest.status === 'publishing') return { label: 'publishing…', tone: 'info' };
  if (pullRequest.status === 'failed') {
    return pullRequest.head_commit && !pullRequest.number
      ? { label: 'branch published, pull request not opened', tone: 'error' }
      : { label: 'failed', tone: 'error' };
  }
  if (pullRequest.state === 'merged') return { label: 'merged', tone: 'success' };
  if (pullRequest.state === 'closed') return { label: 'closed', tone: 'muted' };
  if (pullRequest.number) return { label: pullRequest.draft ? 'draft open' : 'open', tone: 'accent' };
  return { label: 'branch published', tone: 'warning' };
}

// When to read the install pull request again, in ms, or null to stop:
// soon while a publish runs, every minute while the pull request is open.
export function installPollDelay(pullRequest) {
  if (!pullRequest) return null;
  if (pullRequest.status === 'queued' || pullRequest.status === 'publishing') return INSTALL_PR_PUBLISH_POLL_INTERVAL_MS;
  if (pullRequest.number && !['merged', 'closed'].includes(pullRequest.state)) return INSTALL_PR_POLL_INTERVAL_MS;
  return null;
}

// What the install card offers:
//   canOpen    a new install pull request: none yet, the last one is closed
//              or merged, or its publish failed before the branch was pushed
//   canUpdate  a new commit on the open pull request's branch
//   openBranch for a branch on GitHub with no pull request: 'regular' after
//              GitHub refused the draft, 'draft' after opening it failed;
//              null otherwise
export function installPullRequestActions(pullRequest) {
  const busy = pullRequest?.status === 'queued' || pullRequest?.status === 'publishing';
  const open = Boolean(pullRequest?.number) && !['merged', 'closed'].includes(pullRequest?.state);
  const startable = !pullRequest || ['merged', 'closed'].includes(pullRequest.state)
    || (!pullRequest.number && !pullRequest.head_commit && pullRequest.status === 'failed');
  let openBranch = null;
  if (!busy && pullRequest?.head_commit && !pullRequest.number) {
    openBranch = pullRequest.status === 'draft_refused' ? 'regular' : 'draft';
  }
  return { canOpen: !busy && startable, canUpdate: !busy && open, openBranch };
}

// The mount-relative path of the install patch for `paths`.
export function installPatchPath(projectId, paths = [], title = '') {
  const query = new URLSearchParams();
  for (const path of paths) query.append('paths[]', path);
  if (title) query.set('title', title);
  const text = query.toString();
  return `/api/projects/${projectId}/install_pull_request/patch${text ? `?${text}` : ''}`;
}
