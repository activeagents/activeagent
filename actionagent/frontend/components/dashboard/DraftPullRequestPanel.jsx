import React, { useState, useEffect, useCallback, useMemo } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { dashboardPath } from '../../utils/dashboardPath';
import { apiErrorMessage, diffLines } from '../../utils/codeSessions.mjs';
import {
  DEFAULT_UPDATE_MESSAGE,
  PULL_REQUEST_POLL_INTERVAL_MS,
  canOpenBranch,
  canUpdate,
  defaultTitle,
  fileStatusLetter,
  formatBytes,
  hasUnreadFiles,
  initialSelection,
  isPublishInProgress,
  needsReload,
  parseAllowlist,
  patchPath,
  publishBlocker,
  publishRequestBody,
  pullRequestStatus,
  revertedFiles,
  selectedFiles,
  selectionSummary,
  toggleSelection,
} from '../../utils/draftPullRequests.mjs';
import { StatusBadge } from './CodeSessionPanel';

const DIFF_LINE_CLASSES = {
  add: { dark: 'text-green-400', light: 'text-green-700' },
  del: { dark: 'text-red-400', light: 'text-red-700' },
  hunk: { dark: 'text-blue-300', light: 'text-blue-700' },
  meta: { dark: 'text-gray-400 font-semibold', light: 'text-gray-500 font-semibold' },
  context: { dark: 'text-gray-300', light: 'text-gray-700' },
};

// The server's messages end without a full stop.
function sentence(text) {
  return /[.!?]$/.test(text) ? text : `${text}.`;
}

function useClasses() {
  const { darkMode } = useTheme();
  return {
    darkMode,
    muted: darkMode ? 'text-gray-400' : 'text-gray-500',
    strong: darkMode ? 'text-white' : 'text-gray-900',
    border: darkMode ? 'border-gray-700' : 'border-gray-200',
    link: `underline ${darkMode ? 'text-gray-300 hover:text-white' : 'text-gray-700 hover:text-gray-900'}`,
    secondaryButton: `px-3 py-1 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`,
    primaryButton: 'px-3 py-1 text-sm bg-red-500 text-white rounded hover:bg-red-600 disabled:opacity-50',
    input: `w-full px-3 py-2 border rounded-lg text-sm ${darkMode ? 'bg-gray-800 border-gray-700 text-white placeholder-gray-500' : 'bg-white border-gray-300 text-gray-900'}`,
    errorBox: `p-2 rounded text-xs border ${darkMode ? 'bg-red-900/20 border-red-800 text-red-300' : 'bg-red-50 border-red-200 text-red-700'}`,
    surface: { backgroundColor: darkMode ? '#1a1a1a' : '#ffffff' },
  };
}

// Settings -> Integrations: publishing a ready checkout sandbox's changes as
// a draft pull request. Shows the pull request this sandbox opened (polled
// while a publish runs), the buttons that open the dialog, and the patch to
// download when publishing is not available.
export default function DraftPullRequestPanel({ sandbox, codeSession = null }) {
  const base = `/api/sandboxes/${encodeURIComponent(sandbox.session_id)}/pull_request`;
  const [status, setStatus] = useState(null); // { pull_request, publishing }
  const [error, setError] = useState(null);
  const [dialog, setDialog] = useState(null); // { mode: 'create' | 'update' | 'patch' } while the dialog is open
  const [tick, setTick] = useState(0);
  const [opening, setOpening] = useState(false);

  const load = useCallback(async () => {
    const res = await fetch(base);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(apiErrorMessage(data, `Could not load the pull request (HTTP ${res.status}).`));
    return data;
  }, [base]);

  useEffect(() => {
    let cancelled = false;
    let timer = null;
    const poll = async () => {
      try {
        const data = await load();
        if (cancelled) return;
        setStatus(data);
        setError(null);
        if (isPublishInProgress(data.pull_request)) timer = setTimeout(poll, PULL_REQUEST_POLL_INTERVAL_MS);
      } catch (e) {
        if (!cancelled) setError(e.message);
      }
    };
    poll();
    return () => { cancelled = true; clearTimeout(timer); };
  }, [load, tick]);

  // Opens a pull request for a branch that was published without one: a
  // draft, or a regular one after GitHub refused the draft.
  const openBranch = async (regular) => {
    setOpening(true);
    setError(null);
    try {
      const res = await fetch(base, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(regular ? { regular: true } : { open: true }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `Could not open the pull request (HTTP ${res.status}).`));
      setTick((value) => value + 1);
    } catch (e) {
      setError(e.message);
    } finally {
      setOpening(false);
    }
  };

  const pullRequest = status?.pull_request || null;
  const publishing = status?.publishing || null;
  if (publishing && !publishing.supported) return null;

  return (
    <>
      <PullRequestCard
        pullRequest={pullRequest}
        publishing={publishing}
        error={error}
        opening={opening}
        onOpenDialog={(mode) => setDialog({ mode })}
        onOpenBranch={openBranch}
      />
      {dialog && (
        <DraftPullRequestDialog
          codeSession={codeSession}
          sandbox={sandbox}
          pullRequest={pullRequest}
          publishing={publishing}
          mode={dialog.mode}
          onClose={() => setDialog(null)}
          onPublished={() => { setDialog(null); setTick((value) => value + 1); }}
        />
      )}
    </>
  );
}

// The pull request this sandbox opened, if any, and what can be done next.
export function PullRequestCard({ pullRequest, publishing, error, opening, onOpenDialog, onOpenBranch }) {
  const classes = useClasses();
  const { muted, strong, border, link, secondaryButton, primaryButton, errorBox } = classes;
  const { label, tone } = pullRequestStatus(pullRequest);
  const inProgress = isPublishInProgress(pullRequest);
  const available = Boolean(publishing?.available);
  const update = canUpdate(pullRequest);
  const branchOnly = canOpenBranch(pullRequest);

  return (
    <div className={`mt-2 p-3 rounded-lg border space-y-2 ${border}`}>
      <div className="flex items-center justify-between gap-3">
        <p className={`text-sm font-medium ${strong}`}>Pull request</p>
        <div className="flex items-center gap-2">
          {publishing?.patch_available && !available && (
            <button type="button" onClick={() => onOpenDialog('patch')} className={secondaryButton}>Download patch…</button>
          )}
          {available && update && (
            <button type="button" onClick={() => onOpenDialog('update')} disabled={inProgress} className={`${secondaryButton} disabled:opacity-50`}>
              Update draft PR
            </button>
          )}
          {available && (
            <button type="button" onClick={() => onOpenDialog('create')} disabled={inProgress} className={primaryButton}>
              Open draft PR
            </button>
          )}
        </div>
      </div>

      {publishing && !available && (
        <p className={`text-xs ${muted}`}>
          {sentence(publishing.refusal || 'Publishing is not available for this sandbox')}
          {publishing.patch_available && ' You can download its changes as a patch instead.'}
        </p>
      )}

      {pullRequest && (
        <div className="space-y-1">
          <div className="flex items-center gap-2 min-w-0 text-sm">
            <StatusBadge tone={tone}>{label}</StatusBadge>
            {pullRequest.url ? (
              <a href={pullRequest.url} target="_blank" rel="noopener noreferrer" className={`truncate ${link}`}>
                #{pullRequest.number} {pullRequest.title}
              </a>
            ) : (
              <span className={`truncate ${strong}`}>{pullRequest.title}</span>
            )}
          </div>
          <p className={`text-xs font-mono truncate ${muted}`}>
            {pullRequest.branch}{pullRequest.base_branch ? ` → ${pullRequest.base_branch}` : ''}
            {pullRequest.files?.length ? ` · ${pullRequest.files.length} file${pullRequest.files.length === 1 ? '' : 's'}` : ''}
          </p>
          {pullRequest.status === 'draft_refused' && <p className={`text-xs ${muted}`}>{pullRequest.error_message}</p>}
          {pullRequest.status === 'failed' && pullRequest.error_message && (
            <p className={errorBox}>{pullRequest.error_message}</p>
          )}
          {branchOnly && (
            <div className="flex flex-wrap items-center gap-3 text-xs">
              {pullRequest.compare_url && (
                <a href={pullRequest.compare_url} target="_blank" rel="noopener noreferrer" className={link}>Compare on GitHub</a>
              )}
              {available && (
                <button
                  type="button"
                  onClick={() => onOpenBranch(pullRequest.status === 'draft_refused')}
                  disabled={opening}
                  className={`${secondaryButton} disabled:opacity-50`}
                >
                  {opening && 'Opening…'}
                  {!opening && (pullRequest.status === 'draft_refused' ? 'Open as a regular pull request' : 'Open the draft PR again')}
                </button>
              )}
            </div>
          )}
        </div>
      )}
      {error && <div className={errorBox}>{error}</div>}
    </div>
  );
}

// Reads the preview, then publishes what the user chose: the stateful half
// of the dialog. A publish the server refuses because a file changed since
// the preview reads the preview again.
function DraftPullRequestDialog({ sandbox, pullRequest, publishing, mode, onClose, onPublished, codeSession }) {
  const base = `/api/sandboxes/${encodeURIComponent(sandbox.session_id)}/pull_request`;
  const update = mode === 'update';
  const [preview, setPreview] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [selection, setSelection] = useState(new Set());
  const [title, setTitle] = useState(update ? pullRequest?.title || '' : defaultTitle(sandbox));
  const [body, setBody] = useState('');
  const [branch, setBranch] = useState(update ? pullRequest?.branch || '' : '');
  const [message, setMessage] = useState(DEFAULT_UPDATE_MESSAGE);
  const [allowlistText, setAllowlistText] = useState('');
  const [allowlist, setAllowlist] = useState(null);
  const [submitting, setSubmitting] = useState(false);
  const [reloadTick, setReloadTick] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const res = await fetch(`${base}/preview`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(allowlist ? { allowlist } : {}),
        });
        const data = await res.json().catch(() => ({}));
        if (cancelled) return;
        if (!res.ok) throw new Error(apiErrorMessage(data, `Could not read the sandbox's changes (HTTP ${res.status}).`));
        setPreview(data.preview);
        setSelection(initialSelection(data.preview.files));
        setBranch((current) => current || data.preview.suggested_branch || '');
      } catch (e) {
        if (!cancelled) setError(e.message);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [base, reloadTick, allowlist]);

  const submit = async () => {
    setSubmitting(true);
    setError(null);
    try {
      const res = await fetch(base, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ...publishRequestBody({ files: preview?.files, selection, title, body, branch, message, allowlist, update }), ...(codeSession && !update ? { code_session_id: codeSession.id } : {}) }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        if (needsReload(data.code)) setReloadTick((value) => value + 1);
        throw new Error(apiErrorMessage(data, `Could not publish (HTTP ${res.status}).`));
      }
      onPublished(data.pull_request);
    } catch (e) {
      setError(e.message);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <DraftPullRequestDialogView
      sandbox={sandbox}
      preview={preview}
      loading={loading}
      error={error}
      publishing={publishing}
      pullRequest={pullRequest}
      selection={selection}
      onToggle={(path) => setSelection((current) => toggleSelection(current, path))}
      fields={{ title, body, branch, message, allowlist: allowlistText }}
      onField={(name, value) => ({ title: setTitle, body: setBody, branch: setBranch, message: setMessage, allowlist: setAllowlistText })[name](value)}
      allowlistApplied={Boolean(allowlist)}
      onApplyAllowlist={() => { setError(null); setAllowlist(parseAllowlist(allowlistText)); }}
      mode={mode}
      submitting={submitting}
      onSubmit={submit}
      onCancel={onClose}
    />
  );
}

// The dialog as it renders from its props: the changed files with a box for
// each one that may be published (and why the others may not), the exact
// diff of the ticked ones, the fields of the chosen mode and the patch link.
//
//   create  a new branch, with the pull request's title and description
//   update  a commit on the pull request's branch, with its message; the
//           files the branch holds and the update leaves out are named
//   patch   the patch alone, also whenever publishing is not available
//
// `patchHref(paths, title)` gives the patch link's mount-relative path, the
// sandbox's patch by default. Without `onApplyAllowlist` the paths to read
// are not editable, as when the server decides them.
export function DraftPullRequestDialogView({
  sandbox, preview, loading, error, publishing, pullRequest, selection, onToggle, fields, onField, allowlistApplied, onApplyAllowlist,
  mode, submitting, onSubmit, onCancel, patchHref,
}) {
  const classes = useClasses();
  const { muted, strong, border, link, secondaryButton, primaryButton, input, errorBox, darkMode } = classes;
  const files = preview?.files || [];
  const chosen = useMemo(() => selectedFiles(files, selection), [files, selection]);
  const available = Boolean(publishing?.available);
  const patchOnly = mode === 'patch' || !available;
  const update = mode === 'update' && !patchOnly;
  const blocker = preview && !patchOnly
    ? publishBlocker({ files, selection, title: fields.title, branch: fields.branch, message: fields.message, update })
    : null;
  const reverted = update ? revertedFiles(pullRequest, files, selection) : [];
  let verb = 'Open draft PR';
  if (patchOnly) verb = 'Download patch';
  else if (update) verb = 'Update draft PR';
  let summary = `Publishes the files you tick from ${sandbox.repository}@${sandbox.repository_ref} through the GitHub API, as one commit on a new branch.`;
  if (patchOnly) {
    summary = `Downloads the files you tick from ${sandbox.repository}@${sandbox.repository_ref} as a patch for git am or git apply.`;
  } else if (update) {
    summary = 'Publishes the files you tick as one commit on the pull request\'s branch, which then holds the checkout commit with exactly these files changed.';
  }

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4" role="dialog" aria-modal="true" aria-label={verb}>
      <div className={`w-full max-w-4xl max-h-[90vh] overflow-y-auto rounded-lg border p-5 space-y-4 ${border} ${darkMode ? 'bg-gray-900' : 'bg-white'}`}>
        <div className="flex items-start justify-between gap-3">
          <div>
            <p className={`text-lg font-medium ${strong}`}>{verb}</p>
            <p className={`text-xs ${muted}`}>{summary} Nothing under .github/ is ever published.</p>
          </div>
          <button type="button" onClick={onCancel} className={secondaryButton}>Close</button>
        </div>

        {loading && <p className={`text-sm ${muted}`}>Reading the sandbox's changes…</p>}
        {error && <div className={errorBox}>{error}</div>}

        {preview && (
          <>
            {onApplyAllowlist && (hasUnreadFiles(files) || allowlistApplied) && (
              <div className="flex flex-wrap items-end gap-2">
                <label className={`flex-1 min-w-[16rem] text-xs space-y-1 ${muted}`}>
                  <span>Only read paths matching</span>
                  <input
                    type="text"
                    value={fields.allowlist}
                    onChange={(e) => onField('allowlist', e.target.value)}
                    disabled={submitting || loading}
                    placeholder="app/**, lib/*.rb"
                    className={`${input} font-mono`}
                  />
                </label>
                <button type="button" onClick={onApplyAllowlist} disabled={submitting || loading} className={`${secondaryButton} disabled:opacity-50`}>
                  Read again
                </button>
              </div>
            )}

            <div className="space-y-1">
              <p className={`text-xs font-medium uppercase tracking-wide ${muted}`}>Files · {selectionSummary(files, selection)}</p>
              {files.length === 0 && <p className={`text-sm ${muted}`}>The sandbox has no changes.</p>}
              <ul className="space-y-1">
                {files.map((file) => (
                  <li key={file.path} className="flex items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      aria-label={`Publish ${file.path}`}
                      checked={!file.refusal && selection.has(file.path)}
                      disabled={Boolean(file.refusal) || submitting}
                      onChange={() => onToggle(file.path)}
                    />
                    <span className={`w-4 text-xs font-mono ${muted}`}>{fileStatusLetter(file)}</span>
                    <span className={`font-mono truncate ${file.refusal ? muted : strong}`}>{file.path}</span>
                    {file.size != null && file.status !== 'deleted' && <span className={`shrink-0 text-xs ${muted}`}>{formatBytes(file.size)}</span>}
                    {file.refusal && <span className={`shrink-0 text-xs ${darkMode ? 'text-amber-300' : 'text-amber-700'}`}>{file.refusal_message}</span>}
                  </li>
                ))}
              </ul>
            </div>

            {reverted.length > 0 && (
              <p className={`text-xs ${darkMode ? 'text-amber-300' : 'text-amber-700'}`}>
                Not ticked, so returned to how they are in the checkout commit: <span className="font-mono">{reverted.join(', ')}</span>
              </p>
            )}

            {chosen.length > 0 && (
              <div className="space-y-2">
                <p className={`text-xs font-medium uppercase tracking-wide ${muted}`}>What will be published</p>
                {chosen.map((file) => <FileDiff key={file.path} file={file} classes={classes} />)}
              </div>
            )}

            {!patchOnly && (
              <label className={`block text-xs space-y-1 ${muted}`}>
                <span>Branch</span>
                <input
                  type="text"
                  value={fields.branch}
                  onChange={(e) => onField('branch', e.target.value)}
                  disabled={update || submitting}
                  maxLength={200}
                  className={`${input} font-mono`}
                />
              </label>
            )}
            {update ? (
              <label className={`block text-xs space-y-1 ${muted}`}>
                <span>Commit message</span>
                <input
                  type="text"
                  value={fields.message}
                  onChange={(e) => onField('message', e.target.value)}
                  disabled={submitting}
                  className={input}
                />
              </label>
            ) : (
              <label className={`block text-xs space-y-1 ${muted}`}>
                <span>Title</span>
                <input
                  type="text"
                  value={fields.title}
                  onChange={(e) => onField('title', e.target.value)}
                  disabled={submitting}
                  maxLength={256}
                  className={input}
                />
              </label>
            )}
            {!patchOnly && !update && (
              <label className={`block text-xs space-y-1 ${muted}`}>
                <span>Description</span>
                <textarea
                  value={fields.body}
                  onChange={(e) => onField('body', e.target.value)}
                  disabled={submitting}
                  rows={4}
                  className={input}
                />
              </label>
            )}

            <div className="flex flex-wrap items-center justify-between gap-3">
              <p className={`text-xs ${muted}`}>
                {!available && sentence(publishing?.refusal || 'Publishing is not available for this sandbox')}
                {available && blocker}
              </p>
              <div className="flex items-center gap-3">
                {chosen.length > 0 && (
                  <a
                    href={dashboardPath((patchHref || ((paths, title) => patchPath(sandbox.session_id, paths, title)))(
                      chosen.map((file) => file.path), update ? fields.message : fields.title,
                    ))}
                    className={`text-sm ${link}`}
                  >
                    Download patch
                  </a>
                )}
                <button type="button" onClick={onCancel} className={secondaryButton}>Cancel</button>
                {!patchOnly && (
                  <button type="button" onClick={onSubmit} disabled={Boolean(blocker) || submitting} className={primaryButton}>
                    {submitting ? 'Publishing…' : verb}
                  </button>
                )}
              </div>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function FileDiff({ file, classes }) {
  const { muted, border, darkMode, surface } = classes;
  const lines = useMemo(() => diffLines(file.diff), [file.diff]);

  return (
    <div className={`rounded border ${border}`}>
      <p className={`px-2 py-1 text-xs font-mono border-b ${border} ${muted}`}>{file.path}</p>
      {file.binary ? (
        <p className={`px-2 py-1 text-xs ${muted}`}>Binary file, {formatBytes(file.size)}: published as it is in the sandbox.</p>
      ) : (
        <pre className="max-h-72 overflow-auto p-2 text-xs font-mono" style={surface}>
          {lines.map((line, index) => {
            const tone = DIFF_LINE_CLASSES[line.kind] || DIFF_LINE_CLASSES.context;
            // A diff's lines have no identity but their position.
            return <div key={index} className={darkMode ? tone.dark : tone.light}>{line.text || ' '}</div>;
          })}
        </pre>
      )}
    </div>
  );
}
