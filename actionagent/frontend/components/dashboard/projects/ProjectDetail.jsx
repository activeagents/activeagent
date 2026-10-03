import React, { useCallback, useEffect, useState } from 'react';
import { Badge, Button, Card, MicroLabel, MONO, SegmentedControl } from '../primitives';
import ProjectAssistantReads from './ProjectAssistantReads';
import ProjectBootProgress from './ProjectBootProgress';
import ProjectEnvironment from './ProjectEnvironment';
import ProjectInputRequests from './ProjectInputRequests';
import ProjectInstallPullRequest from './ProjectInstallPullRequest';
import ProjectSecretsForm from './ProjectSecretsForm';
import ProjectSetupCard from './ProjectSetupCard';
import { useActionCable } from '../../../hooks/useActionCable';
import { navigateTo } from '../../../utils/dashboardPath';
import { apiErrorMessage } from '../../../utils/codeSessions.mjs';
import { liveUpdate } from '../../../utils/liveUpdates.mjs';
import {
  BOOT_POLL_INTERVAL_MS,
  PREFLIGHT_TONES,
  isBooting,
  secretRows,
  secretsFormProblem,
  secretsPayload,
} from '../../../utils/projects.mjs';
import { setupInProgress } from '../../../utils/projectSetup.mjs';

const STATE_TONES = { ready: 'success', booting: 'info', failed: 'error', expired: 'muted', none: 'muted' };
const INSTALL_LABELS = {
  installed: 'bundles the engine',
  detected: 'installs the engine in the sandbox',
  bootstrapped: 'engine installed in the sandbox',
};

async function readJson(res) {
  return res.json().catch(() => ({}));
}

// A project's page: its boot (steps, elapsed time, log tail), what its
// agents are waiting on, the setup assistant, the agent it evaluates and Run
// evaluation, what the App assistant may read, the install pull request, and
// its Environment tab. The boot is followed through the sandbox's Action
// Cable stream and polled every BOOT_POLL_INTERVAL_MS while it boots or the
// setup assistant works, so it updates without the cable.
export default function ProjectDetail({ projectId, onBack, onDeleted }) {
  const [project, setProject] = useState(null);
  const [boot, setBoot] = useState(null); // { boot, log_tail, error, confirmation }
  const [secrets, setSecrets] = useState([]);
  const [tab, setTab] = useState('overview');
  const [error, setError] = useState(null);
  const [environmentError, setEnvironmentError] = useState(null);
  const [confirmation, setConfirmation] = useState(null); // { question, retry }
  const [busy, setBusy] = useState(false);
  const [run, setRun] = useState(null);
  const [syncedAgents, setSyncedAgents] = useState(null);
  const [newRows, setNewRows] = useState(null);

  const loadBoot = useCallback(async () => {
    const res = await fetch(`/api/projects/${projectId}/boot`);
    const data = await readJson(res);
    if (!res.ok) throw new Error(apiErrorMessage(data, `Could not load the project (HTTP ${res.status}).`));
    setProject(data.project);
    setBoot(data);
  }, [projectId]);

  const loadSecrets = useCallback(async () => {
    const res = await fetch(`/api/projects/${projectId}/secrets`);
    const data = await readJson(res);
    if (!res.ok) throw new Error(apiErrorMessage(data, `Could not list the project's secrets (HTTP ${res.status}).`));
    setSecrets(data.secrets || []);
  }, [projectId]);

  useEffect(() => {
    loadBoot().catch((e) => setError(e.message));
    loadSecrets().catch((e) => setEnvironmentError(e.message));
  }, [loadBoot, loadSecrets]);

  const booting = isBooting(project);
  const watching = booting || setupInProgress(project);
  useEffect(() => {
    if (!watching) return undefined;
    const timer = setTimeout(() => loadBoot().catch((e) => setError(e.message)), BOOT_POLL_INTERVAL_MS);
    return () => clearTimeout(timer);
  }, [watching, boot, loadBoot]);

  const sessionId = project?.sandbox?.session_id;
  useActionCable('SandboxChannel', { session_id: sessionId }, (message) => {
    if (liveUpdate(message)) loadBoot().catch(() => {});
  }, Boolean(sessionId));

  // POSTs `path`; a 409 that asks for confirmation is held until the person
  // confirms, then the same request is sent again with confirm: true.
  // `onDone` gets the response of the request that went through.
  const post = async (path, { confirm = false, onDone } = {}) => {
    setBusy(true);
    setError(null);
    try {
      const res = await fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(confirm ? { confirm: true } : {}),
      });
      const data = await readJson(res);
      if (res.status === 409 && data.code === 'confirmation_required') {
        setConfirmation({ question: data.confirmation, retry: () => post(path, { confirm: true, onDone }) });
        return null;
      }
      if (!res.ok) throw new Error(apiErrorMessage(data, `The request failed (HTTP ${res.status}).`));
      setConfirmation(null);
      if (data.project) setProject(data.project);
      await loadBoot();
      onDone?.(data);
      return data;
    } catch (e) {
      setError(e.message);
      return null;
    } finally {
      setBusy(false);
    }
  };

  const runEvaluation = () => post(`/api/projects/${projectId}/run_evaluation`, {
    onDone: (data) => { if (data.run) setRun(data.run); },
  });

  // A view that boots the sandbox asks for the same confirmation; `retry`
  // sends its request again once it is given.
  const askConfirmation = (question, retry) => setConfirmation({ question, retry });

  const setupRequest = async (method, body) => {
    setBusy(true);
    setError(null);
    try {
      const res = await fetch(`/api/projects/${projectId}/setup`, {
        method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}),
      });
      const data = await readJson(res);
      if (!res.ok) throw new Error(apiErrorMessage(data, `The setup assistant request failed (HTTP ${res.status}).`));
      if (data.project) setProject(data.project);
      await loadBoot();
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  const loadSyncedAgents = async () => {
    setError(null);
    const res = await fetch(`/api/projects/${projectId}/synced_agents`);
    const data = await readJson(res);
    if (!res.ok) {
      setError(apiErrorMessage(data, `Could not list the checkout's agents (HTTP ${res.status}).`));
      return;
    }
    setSyncedAgents(data.synced_agents || []);
  };

  const chooseTarget = async (body) => {
    setBusy(true);
    try {
      const res = await fetch(`/api/projects/${projectId}/target`, {
        method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      const data = await readJson(res);
      if (!res.ok) throw new Error(apiErrorMessage(data, `Could not choose the agent (HTTP ${res.status}).`));
      setProject(data.project);
      setSyncedAgents(null);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  const saveSecrets = async (list) => {
    setEnvironmentError(null);
    const res = await fetch(`/api/projects/${projectId}/secrets`, {
      method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ secrets: list }),
    });
    const data = await readJson(res);
    if (!res.ok) {
      setEnvironmentError(apiErrorMessage(data, `Could not save the secrets (HTTP ${res.status}).`));
      return false;
    }
    setSecrets(data.secrets || []);
    return true;
  };

  const replaceSecret = async (name, value) => {
    setEnvironmentError(null);
    const res = await fetch(`/api/projects/${projectId}/secrets/${encodeURIComponent(name)}`, {
      method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ value }),
    });
    const data = await readJson(res);
    if (!res.ok) {
      const message = apiErrorMessage(data, `Could not replace ${name} (HTTP ${res.status}).`);
      setEnvironmentError(message);
      throw new Error(message);
    }
    await loadSecrets();
  };

  const deleteSecret = async (name) => {
    setEnvironmentError(null);
    const res = await fetch(`/api/projects/${projectId}/secrets/${encodeURIComponent(name)}`, { method: 'DELETE' });
    if (!res.ok) {
      setEnvironmentError(apiErrorMessage(await readJson(res), `Could not delete ${name} (HTTP ${res.status}).`));
      return;
    }
    await loadSecrets();
  };

  const findMissing = async () => {
    setEnvironmentError(null);
    const query = `repository=${encodeURIComponent(project.repository)}&project_id=${projectId}${project.default_ref ? `&ref=${encodeURIComponent(project.default_ref)}` : ''}`;
    const res = await fetch(`/api/projects/discover_secrets?${query}`);
    const data = await readJson(res);
    if (!res.ok) {
      setEnvironmentError(apiErrorMessage(data, `Could not read the repository's environment variables (HTTP ${res.status}).`));
      return;
    }
    setNewRows(secretRows(data.variables || [], secrets));
  };

  const destroy = async () => {
    if (!window.confirm(`Delete ${project.name}? Its secrets, agent and evaluation are deleted, and its sandbox is stopped.`)) return;
    const res = await fetch(`/api/projects/${projectId}`, { method: 'DELETE' });
    if (res.ok) onDeleted(); else setError(apiErrorMessage(await readJson(res), `Could not delete the project (HTTP ${res.status}).`));
  };

  if (!project) {
    return error
      ? <div style={{ fontSize: 13, color: 'var(--color-error-text)' }}>{error}</div>
      : <div style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>Loading the project…</div>;
  }

  const target = project.target_agent;
  const needsPick = !target && project.install_state === 'installed';

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }} data-testid="project-detail">
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 16, flexWrap: 'wrap' }}>
        <div style={{ flex: 1, minWidth: 260 }}>
          <Button size="sm" variant="ghost" onClick={onBack} style={{ padding: 0 }}>← Projects</Button>
          <h1 style={{ margin: '4px 0 0', fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>{project.name}</h1>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginTop: 4, flexWrap: 'wrap' }}>
            <span style={{ fontFamily: MONO, fontSize: 13, color: 'var(--color-text-secondary)' }}>
              {project.repository}{project.default_ref ? `@${project.default_ref}` : ''}
            </span>
            <Badge tone={STATE_TONES[project.sandbox_state] || 'muted'}>sandbox {project.sandbox_state}</Badge>
            <Badge tone={PREFLIGHT_TONES[project.install_state === 'installed' ? 'supported' : 'bootstrap']}>{INSTALL_LABELS[project.install_state]}</Badge>
          </div>
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <Button onClick={() => post(`/api/projects/${projectId}/boot`)} disabled={busy || booting} testId="boot-project">
            {project.sandbox_state === 'ready' ? 'Sandbox running' : booting ? 'Booting…' : 'Boot sandbox'}
          </Button>
          <Button variant="primary" onClick={() => runEvaluation()} disabled={busy || !target} testId="run-project-evaluation"
            title={target ? 'Boots the sandbox first when it is not running' : 'Choose the agent to evaluate first'}>
            Run evaluation
          </Button>
        </div>
      </div>

      {confirmation && (
        <Card testId="local-boot-confirmation" style={{ borderColor: 'var(--color-warning)' }}>
          <p style={{ margin: 0, fontSize: 14, color: 'var(--color-text-primary)' }}>{confirmation.question}</p>
          <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
            <Button variant="primary" onClick={() => { const { retry } = confirmation; setConfirmation(null); retry?.(); }} disabled={busy}>
              Run it on this machine
            </Button>
            <Button onClick={() => setConfirmation(null)}>Cancel</Button>
          </div>
        </Card>
      )}

      {error && (
        <div style={{ padding: '10px 12px', borderRadius: 8, fontSize: 13, background: 'var(--color-error-soft)', color: 'var(--color-error-text)' }}>{error}</div>
      )}

      <SegmentedControl
        options={[{ value: 'overview', label: 'Overview' }, { value: 'environment', label: `Environment (${secrets.length})` }]}
        value={tab}
        onChange={setTab}
      />

      {tab === 'overview' && (
        <>
          <ProjectBootProgress boot={boot?.boot} logTail={boot?.log_tail} error={boot?.error} sandboxState={project.sandbox_state}
            waiting={project.pending_input_requests} />

          <ProjectInputRequests
            projectId={projectId}
            setupAgentId={project.setup?.agent_id}
            version={`${project.pending_input_requests}:${project.setup?.last_run?.id}:${project.setup?.last_run?.status}`}
            onSettled={() => loadBoot().catch(() => {})}
          />

          <ProjectSetupCard
            project={project}
            busy={busy}
            onAsk={() => setupRequest('POST')}
            onToggleAuto={(auto) => setupRequest('PATCH', { auto })}
          />

          <Card>
            <MicroLabel>Agent under evaluation</MicroLabel>
            {target && (
              <div style={{ marginTop: 8, display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                <span style={{ fontSize: 14, fontWeight: 600, color: 'var(--color-text-primary)' }}>{target.name}</span>
                <Badge tone="accent">{target.kind === 'app_assistant' ? 'App assistant' : `synced agent ${target.synced_agent}`}</Badge>
                <Button size="sm" variant="ghost" onClick={() => navigateTo(`/agents/${target.id}/edit`)}>Open agent</Button>
                {project.evaluation && (
                  <Button size="sm" variant="ghost" onClick={() => navigateTo(`/evaluations/${project.evaluation.id}`)}>Open evaluation</Button>
                )}
                {project.install_state === 'installed' && <Button size="sm" onClick={loadSyncedAgents}>Change</Button>}
              </div>
            )}
            {needsPick && !syncedAgents && (
              <div style={{ marginTop: 8, fontSize: 13, color: 'var(--color-text-secondary)' }}>
                This repository has its own agents. Boot the sandbox, then pick the one to evaluate.
                <div style={{ marginTop: 8 }}>
                  <Button size="sm" onClick={loadSyncedAgents} disabled={project.sandbox_state !== 'ready'}>List the checkout's agents</Button>
                </div>
              </div>
            )}
            {syncedAgents && (
              <ul style={{ listStyle: 'none', margin: '8px 0 0', padding: 0 }} data-testid="synced-agents">
                {syncedAgents.length === 0 && <li style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>The sandbox serves no agents.</li>}
                {syncedAgents.map((agent) => (
                  <li key={agent.slug} style={{ display: 'flex', gap: 8, alignItems: 'center', padding: '6px 0' }}>
                    <span style={{ fontFamily: MONO, fontSize: 13 }}>{agent.tool}</span>
                    <span style={{ fontSize: 12, color: 'var(--color-text-secondary)', flex: 1 }}>{agent.description}</span>
                    <Button size="sm" onClick={() => chooseTarget({ synced_agent: agent.slug })} disabled={busy}>Evaluate this agent</Button>
                  </li>
                ))}
              </ul>
            )}
            {run && (
              <div data-testid="project-run" style={{ marginTop: 10, fontSize: 13, color: 'var(--color-text-secondary)' }}>
                Run {run.id} is {run.status}{booting ? ': it starts once the sandbox is ready' : ''}.{' '}
                <Button size="sm" variant="ghost" onClick={() => navigateTo(`/evaluations/${run.evaluation_id}/runs/${run.id}`)}>Open run</Button>
              </div>
            )}
          </Card>

          {target?.kind === 'app_assistant' && (
            <ProjectAssistantReads
              project={project}
              onSaved={(next) => { if (next) setProject(next); loadBoot().catch(() => {}); }}
              onConfirmationRequired={askConfirmation}
            />
          )}

          <ProjectInstallPullRequest
            project={project}
            onProjectChanged={(next) => setProject((current) => (current && next.install_state !== current.install_state ? next : current))}
            onConfirmationRequired={askConfirmation}
          />

          <div>
            <Button variant="danger" size="sm" onClick={destroy}>Delete project</Button>
          </div>
        </>
      )}

      {tab === 'environment' && (
        <>
          <ProjectEnvironment secrets={secrets} onReplace={replaceSecret} onDelete={deleteSecret} error={environmentError} />
          {newRows ? (
            <Card>
              <MicroLabel>Add secrets</MicroLabel>
              <div style={{ marginTop: 8 }}>
                <ProjectSecretsForm rows={newRows} onChange={setNewRows} repository={project.repository} />
              </div>
              <div style={{ display: 'flex', gap: 8, marginTop: 12, alignItems: 'center' }}>
                <Button
                  variant="primary"
                  disabled={Boolean(secretsFormProblem(newRows)) || secretsPayload(newRows).length === 0}
                  onClick={async () => { if (await saveSecrets(secretsPayload(newRows))) setNewRows(null); }}
                >
                  Save secrets
                </Button>
                <Button onClick={() => setNewRows(null)}>Cancel</Button>
                {secretsFormProblem(newRows) && <span style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>{secretsFormProblem(newRows)}</span>}
              </div>
            </Card>
          ) : (
            <div><Button size="sm" onClick={findMissing}>Add secrets</Button></div>
          )}
        </>
      )}
    </div>
  );
}
