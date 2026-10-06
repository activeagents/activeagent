import React, { useCallback, useEffect, useState } from 'react';
import { Badge, Button, Card, MicroLabel, MONO } from '../primitives';
import { DraftPullRequestDialogView } from '../DraftPullRequestPanel';
import { apiErrorMessage } from '../../../utils/codeSessions.mjs';
import { DEFAULT_UPDATE_MESSAGE, initialSelection, needsReload, publishRequestBody, toggleSelection } from '../../../utils/draftPullRequests.mjs';
import { installPatchPath, installPollDelay, installPullRequestActions, installPullRequestStatus } from '../../../utils/projectSetup.mjs';

async function readJson(res) {
  return res.json().catch(() => ({}));
}

// The project's install pull request: its status (read again every minute
// while it is open, and the project counts as installed once it merges),
// Open install PR and Update draft PR, each through the publish dialog,
// which shows the exact diff of what the project's allowlist lets through.
export default function ProjectInstallPullRequest({ project, onProjectChanged, onConfirmationRequired }) {
  const base = `/api/projects/${project.id}/install_pull_request`;
  const [status, setStatus] = useState(null); // { pull_request, publishing, allowlist }
  const [error, setError] = useState(null);
  const [dialog, setDialog] = useState(null); // 'create' | 'update'
  const [tick, setTick] = useState(0);
  const [opening, setOpening] = useState(false);

  const load = useCallback(async () => {
    const res = await fetch(base);
    const data = await readJson(res);
    if (!res.ok) throw new Error(apiErrorMessage(data, `Could not read the install pull request (HTTP ${res.status}).`));
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
        if (data.project) onProjectChanged?.(data.project);
        const delay = installPollDelay(data.pull_request);
        if (delay) timer = setTimeout(poll, delay);
      } catch (e) {
        if (!cancelled) setError(e.message);
      }
    };
    poll();
    return () => { cancelled = true; clearTimeout(timer); };
  }, [load, tick]);

  const openBranch = async (regular) => {
    setOpening(true);
    setError(null);
    try {
      const res = await fetch(base, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(regular ? { regular: true } : { open: true }),
      });
      const data = await readJson(res);
      if (!res.ok) throw new Error(apiErrorMessage(data, `Could not open the pull request (HTTP ${res.status}).`));
      setTick((value) => value + 1);
    } catch (e) {
      setError(e.message);
    } finally {
      setOpening(false);
    }
  };

  const pullRequest = status?.pull_request || null;
  if (project.install_state === 'installed' && !pullRequest) return null;

  return (
    <>
      <InstallPullRequestCard
        project={project}
        pullRequest={pullRequest}
        publishing={status?.publishing}
        allowlist={status?.allowlist || []}
        error={error}
        opening={opening}
        onOpenDialog={setDialog}
        onOpenBranch={openBranch}
      />
      {dialog && (
        <InstallPullRequestDialog
          project={project}
          base={base}
          pullRequest={pullRequest}
          mode={dialog}
          onConfirmationRequired={onConfirmationRequired}
          onClose={() => setDialog(null)}
          onPublished={() => { setDialog(null); setTick((value) => value + 1); }}
        />
      )}
    </>
  );
}

// The card as it renders from its props.
export function InstallPullRequestCard({ project, pullRequest, publishing, allowlist, error, opening, onOpenDialog, onOpenBranch }) {
  const { label, tone } = installPullRequestStatus(pullRequest);
  const { canOpen, canUpdate, openBranch } = installPullRequestActions(pullRequest);

  return (
    <Card testId="project-install-pull-request">
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <MicroLabel>Install pull request</MicroLabel>
        <Badge tone={tone}>{label}</Badge>
        {pullRequest?.url && (
          <a href={pullRequest.url} target="_blank" rel="noopener noreferrer" style={{ fontSize: 13, color: 'var(--color-info)' }}>
            #{pullRequest.number}
          </a>
        )}
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          {canUpdate && <Button size="sm" onClick={() => onOpenDialog('update')}>Update draft PR</Button>}
          {canOpen && project.install_state !== 'installed' && (
            <Button size="sm" variant="primary" onClick={() => onOpenDialog('create')} testId="open-install-pr">Open install PR</Button>
          )}
          {openBranch && (
            <Button size="sm" onClick={() => onOpenBranch(openBranch === 'regular')} disabled={opening} testId="open-install-branch">
              {opening ? 'Opening…' : openBranch === 'regular' ? 'Open as a regular pull request' : 'Open the draft PR again'}
            </Button>
          )}
        </span>
      </div>
      <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--color-text-secondary)' }}>
        {project.install_state === 'installed'
          ? 'The pull request merged: the repository bundles the engine, and boots its own branch.'
          : 'Publishes what the sandbox installed as a draft pull request, from this dashboard, after you check the exact diff. ' +
            'Once it exists, every boot checks its branch out.'}
      </p>
      {pullRequest?.branch && (
        <p style={{ margin: '4px 0 0', fontFamily: MONO, fontSize: 12, color: 'var(--color-text-muted)' }}>
          {pullRequest.branch}{pullRequest.base_branch ? ` → ${pullRequest.base_branch}` : ''}
        </p>
      )}
      {pullRequest?.status === 'failed' && pullRequest.error_message && (
        <p style={{ margin: '6px 0 0', fontSize: 12, color: 'var(--color-error-text)' }}>{pullRequest.error_message}</p>
      )}
      {publishing && !publishing.available && publishing.live && (
        <p style={{ margin: '6px 0 0', fontSize: 12, color: 'var(--color-text-secondary)' }}>{publishing.refusal}</p>
      )}
      {allowlist.length > 0 && (
        <details style={{ marginTop: 6 }}>
          <summary style={{ cursor: 'pointer', fontSize: 12, color: 'var(--color-text-secondary)' }}>What it may publish</summary>
          <ul style={{ margin: '4px 0 0', paddingLeft: 18, fontFamily: MONO, fontSize: 12, color: 'var(--color-text-secondary)' }}>
            {allowlist.map((entry) => <li key={entry}>{entry}</li>)}
          </ul>
        </details>
      )}
      {error && <p style={{ margin: '6px 0 0', fontSize: 12, color: 'var(--color-error-text)' }}>{error}</p>}
    </Card>
  );
}

// Reads the preview (booting the sandbox first when it is not running), then
// publishes what the user chose.
function InstallPullRequestDialog({ project, base, pullRequest, mode, onConfirmationRequired, onClose, onPublished }) {
  const update = mode === 'update';
  const [preview, setPreview] = useState(null);
  const [publishing, setPublishing] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [selection, setSelection] = useState(new Set());
  const [title, setTitle] = useState(update ? pullRequest?.title || '' : 'Install ActiveAgent');
  const [body, setBody] = useState('');
  const [branch, setBranch] = useState(update ? pullRequest?.branch || '' : '');
  const [message, setMessage] = useState(DEFAULT_UPDATE_MESSAGE);
  const [submitting, setSubmitting] = useState(false);
  const [reloadTick, setReloadTick] = useState(0);

  useEffect(() => {
    let cancelled = false;
    let timer = null;
    setLoading(true);
    const read = async (confirm = false) => {
      try {
        const res = await fetch(`${base}/preview`, {
          method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(confirm ? { confirm: true } : {}),
        });
        const data = await readJson(res);
        if (cancelled) return;
        if (res.status === 409 && data.code === 'confirmation_required') {
          onConfirmationRequired?.(data.confirmation, () => read(true));
          return;
        }
        if (res.status === 202) {
          setError(data.error);
          timer = setTimeout(() => read(), 3000);
          return;
        }
        if (!res.ok) throw new Error(apiErrorMessage(data, `Could not read the sandbox's changes (HTTP ${res.status}).`));
        setError(null);
        setPreview(data.preview);
        setPublishing(data.publishing);
        setSelection(initialSelection(data.preview.files));
        setBranch((current) => current || data.preview.suggested_branch || '');
        setLoading(false);
      } catch (e) {
        if (!cancelled) { setError(e.message); setLoading(false); }
      }
    };
    read();
    return () => { cancelled = true; clearTimeout(timer); };
  }, [base, reloadTick]);

  const submit = async () => {
    setSubmitting(true);
    setError(null);
    try {
      const request = publishRequestBody({ files: preview?.files, selection, title, body, branch, message, update });
      const res = await fetch(base, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(request) });
      const data = await readJson(res);
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
      sandbox={{ repository: project.repository, repository_ref: project.sandbox?.repository_ref || project.checkout_ref || 'its default branch' }}
      preview={preview}
      loading={loading}
      error={error}
      publishing={publishing}
      pullRequest={pullRequest}
      selection={selection}
      onToggle={(path) => setSelection((current) => toggleSelection(current, path))}
      fields={{ title, body, branch, message, allowlist: '' }}
      onField={(name, value) => ({ title: setTitle, body: setBody, branch: setBranch, message: setMessage })[name]?.(value)}
      allowlistApplied={false}
      mode={update ? 'update' : 'create'}
      submitting={submitting}
      onSubmit={submit}
      onCancel={onClose}
      patchHref={(paths, patchTitle) => installPatchPath(project.id, paths, patchTitle)}
    />
  );
}
