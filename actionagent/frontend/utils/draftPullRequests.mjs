// Pure helpers for opening a draft pull request from a checkout sandbox
// (Settings -> Integrations). The server decides what may be published; these
// only shape what it reported for the dialog and the pull request card.

export const PULL_REQUEST_POLL_INTERVAL_MS = 2000;

// The commit message an update suggests. The server uses the same one when
// it is given none.
export const DEFAULT_UPDATE_MESSAGE = 'Update from the sandbox';

const IN_PROGRESS = new Set(['queued', 'publishing']);

// Whether the last publish is still to run or running.
export function isPublishInProgress(pullRequest) {
  return Boolean(pullRequest && IN_PROGRESS.has(pullRequest.status));
}

// How the card labels a pull request: { label, tone }, the tone one of
// StatusBadge's.
export function pullRequestStatus(pullRequest) {
  if (!pullRequest) return { label: 'None', tone: 'neutral' };
  switch (pullRequest.status) {
    case 'queued': return { label: 'Queued', tone: 'progress' };
    case 'publishing': return { label: 'Publishing', tone: 'progress' };
    case 'draft_refused': return { label: 'Branch published', tone: 'neutral' };
    case 'failed':
      if (pullRequest.number) return { label: `${stateLabel(pullRequest)} · update failed`, tone: 'error' };
      if (pullRequest.head_commit) return { label: 'Branch published · pull request not opened', tone: 'error' };
      return { label: 'Failed', tone: 'error' };
    default: return { label: stateLabel(pullRequest), tone: stateTone(pullRequest) };
  }
}

function stateLabel(pullRequest) {
  if (pullRequest.state === 'merged') return 'Merged';
  if (pullRequest.state === 'closed') return 'Closed';
  return pullRequest.draft ? 'Draft' : 'Open';
}

function stateTone(pullRequest) {
  if (pullRequest.state === 'closed') return 'error';
  if (pullRequest.state === 'merged') return 'success';
  return pullRequest.draft ? 'neutral' : 'success';
}

// Whether a new commit can go onto the pull request's branch: the pull
// request is open on GitHub, not closed or merged.
export function canUpdate(pullRequest) {
  if (!pullRequest?.head_commit || !pullRequest.number || isPublishInProgress(pullRequest)) return false;
  return !['closed', 'merged'].includes(pullRequest.state);
}

// Whether the branch is on GitHub with no pull request for it, so one can be
// opened: GitHub refused the draft, or opening it failed.
export function canOpenBranch(pullRequest) {
  return Boolean(pullRequest?.head_commit && !pullRequest.number && !isPublishInProgress(pullRequest));
}

// The files on the pull request's branch that an update with +selection+
// returns to the checkout commit, since the branch holds only the files of
// its last publish: those not ticked, refused, or no longer changed.
export function revertedFiles(pullRequest, files, selection) {
  const chosen = new Set(selectedFiles(files, selection).map((file) => file.path));
  return (pullRequest?.files || []).map((file) => file.path).filter((path) => !chosen.has(path));
}

// Whether the preview stopped reading before some file, which then needs
// fewer paths to be read.
export function hasUnreadFiles(files) {
  return (files || []).some((file) => file.refusal === 'not_read');
}

// The path patterns typed in the dialog ("app/**, lib/*.rb"), or null for
// none: separated by commas, spaces or new lines.
export function parseAllowlist(text) {
  const patterns = (text || '').split(/[\s,]+/).filter(Boolean);
  return patterns.length ? patterns : null;
}

// Errors after which the dialog reads the sandbox again rather than
// letting the user retry what they saw.
export function needsReload(code) {
  return code === 'changed_since_preview';
}

// The files ticked when the dialog opens: every one that may be published.
export function initialSelection(files) {
  return new Set((files || []).filter((file) => !file.refusal).map((file) => file.path));
}

export function toggleSelection(selection, path) {
  const next = new Set(selection);
  if (next.has(path)) next.delete(path); else next.add(path);
  return next;
}

// The previewed files a selection ticks, in the preview's order.
export function selectedFiles(files, selection) {
  return (files || []).filter((file) => !file.refusal && selection.has(file.path));
}

// "3 of 4 files selected · 2 cannot be published".
export function selectionSummary(files, selection) {
  const list = files || [];
  const publishable = list.filter((file) => !file.refusal);
  const refused = list.length - publishable.length;
  const chosen = selectedFiles(list, selection).length;
  const noun = publishable.length === 1 ? 'file' : 'files';
  const parts = [`${chosen} of ${publishable.length} ${noun} selected`];
  if (refused > 0) parts.push(`${refused} cannot be published`);
  return parts.join(' · ');
}

// One letter per status, as git prints them.
export function fileStatusLetter(file) {
  return { added: 'A', modified: 'M', deleted: 'D' }[file.status] || '?';
}

const BRANCH_FORBIDDEN = /[\x00-\x20\x7f~^:?*[\\]|\.\.|@\{|\/\/|^[/-]|\/$|\.$|^@$/;

// Why +name+ cannot be a branch, or null. Mirrors
// DraftPullRequestPublisher.branch_refusal, so the dialog says so before
// the server does.
export function branchNameError(name) {
  const value = (name || '').trim();
  if (!value) return 'Name the branch.';
  if (value.length > 200) return 'A branch name is at most 200 characters.';
  if (!/^[\x00-\x7f]*$/.test(value) || BRANCH_FORBIDDEN.test(value)
    || value.split('/').some((part) => part.startsWith('.') || part.endsWith('.lock'))) {
    return `"${value}" is not a valid branch name.`;
  }
  return null;
}

// Why the dialog's publish button is off, or null. An update needs a commit
// message rather than a title and a branch.
export function publishBlocker({ files, selection, title, branch, message, update = false }) {
  if (selectedFiles(files, selection).length === 0) return 'Choose at least one file.';
  if (update) return (message || '').trim() ? null : 'Add a commit message.';
  if (!(title || '').trim()) return 'Add a title.';
  return branchNameError(branch);
}

// The body of POST /api/sandboxes/:id/pull_request for the dialog's choices.
// +allowlist+ is sent when the preview was read with one.
export function publishRequestBody({ files, selection, title, body, branch, message, allowlist = null, update = false }) {
  const chosen = selectedFiles(files, selection).map((file) => ({ path: file.path, digest: file.digest }));
  const request = update
    ? { files: chosen, message: (message || '').trim(), update: true }
    : { files: chosen, title: (title || '').trim(), body: body || '', branch: (branch || '').trim() };
  return allowlist ? { ...request, allowlist } : request;
}

// Where the patch of +paths+ downloads from, mount-relative.
export function patchPath(sessionId, paths, title) {
  const query = new URLSearchParams();
  (paths || []).forEach((path) => query.append('paths[]', path));
  if (title && title.trim()) query.set('title', title.trim());
  const search = query.toString();
  return `/api/sandboxes/${encodeURIComponent(sessionId)}/pull_request/patch${search ? `?${search}` : ''}`;
}

// "12 KB", "3 bytes": how big a file is.
export function formatBytes(bytes) {
  const value = Number(bytes);
  if (!Number.isFinite(value) || value < 0) return '';
  if (value < 1024) return `${value} ${value === 1 ? 'byte' : 'bytes'}`;
  if (value < 1024 * 1024) return `${Math.round(value / 1024)} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}

// The title the dialog suggests until the user writes one.
export function defaultTitle(sandbox) {
  return sandbox?.repository ? `Changes from a sandbox of ${sandbox.repository}` : 'Changes from a sandbox';
}
