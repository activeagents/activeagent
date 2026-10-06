import React, { useCallback, useEffect, useState } from 'react';
import { Badge, Button, Card, MicroLabel, MONO } from '../primitives';
import RepoPicker from '../RepoPicker';
import CapabilitiesChecklist from './CapabilitiesChecklist';
import ProjectSecretsForm from './ProjectSecretsForm';
import { dashboardPath } from '../../../utils/dashboardPath';
import { apiErrorMessage } from '../../../utils/codeSessions.mjs';
import {
  PREFLIGHT_TONES,
  createProblem,
  projectNameAfterPick,
  repoPickerState,
  secretRows,
  secretsFormProblem,
  secretsPayload,
} from '../../../utils/projects.mjs';

const fieldStyle = {
  width: '100%', padding: '6px 10px', borderRadius: 6, fontSize: 13,
  border: '1px solid var(--color-border)', background: 'var(--color-card)', color: 'var(--color-text-primary)',
};

// What preflight found about the picked repository (GET /api/projects/preflight).
export function PreflightResult({ repository, preflight }) {
  if (!preflight) return null;

  return (
    <div data-testid="project-preflight" style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
        <span style={{ fontFamily: MONO, fontSize: 13, color: 'var(--color-text-primary)' }}>{repository}</span>
        <Badge tone={PREFLIGHT_TONES[preflight.status] || 'muted'}>{preflight.summary}</Badge>
      </div>
      <div style={{ fontFamily: MONO, fontSize: 12, color: 'var(--color-text-muted)' }}>
        Ruby {preflight.ruby || 'unpinned'}{preflight.ruby_source ? ` (${preflight.ruby_source})` : ''} · railties {preflight.railties || 'not locked'}
        {' '}· engine {preflight.actionagent || 'not bundled'} · ref {preflight.ref}
      </div>
      {preflight.reasons?.slice(1).map((reason) => (
        <div key={reason} style={{ fontSize: 13, color: 'var(--color-error-text)' }}>{reason}</div>
      ))}
      {preflight.warnings?.map((warning) => (
        <div key={warning} style={{ fontSize: 13, color: 'var(--color-warning-text)' }}>{warning}</div>
      ))}
    </div>
  );
}

// The New Project page: the capabilities checklist, the repository picker,
// what preflight says about the pick, the secrets its boot needs, and
// Create, which stays disabled while a blocking item fails or the
// repository is not supported.
export default function NewProject({ onCreated, onCancel }) {
  const [capabilities, setCapabilities] = useState(null);
  const [repositories, setRepositories] = useState(null);
  const [reconnectRequired, setReconnectRequired] = useState(false);
  const [filter, setFilter] = useState('');
  const [selected, setSelected] = useState(null);
  const [typedNameError, setTypedNameError] = useState(null);
  const [preflight, setPreflight] = useState(null);
  const [checking, setChecking] = useState(false);
  const [rows, setRows] = useState([]);
  const [name, setName] = useState('');
  const [nameEdited, setNameEdited] = useState(false);
  const [startUrl, setStartUrl] = useState('/');
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState(null);

  const loadCapabilities = useCallback(async () => {
    const res = await fetch('/api/projects/capabilities');
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(apiErrorMessage(data, `Could not check what this dashboard can do (HTTP ${res.status}).`));
    setCapabilities(data);
    return data;
  }, []);

  const loadRepositories = useCallback(async () => {
    setRepositories(null);
    const res = await fetch('/api/github_connection/repositories');
    const data = await res.json().catch(() => ({}));
    if (data.reconnect_required) {
      setReconnectRequired(true);
      return;
    }
    if (!res.ok) throw new Error(apiErrorMessage(data, `Could not list repositories (HTTP ${res.status}).`));
    setReconnectRequired(false);
    setRepositories(data.repositories || []);
  }, []);

  useEffect(() => {
    loadCapabilities()
      .then((data) => (data.github?.connected ? loadRepositories() : null))
      .catch((e) => setError(e.message));
  }, [loadCapabilities, loadRepositories]);

  // Preflight, then discovery, for the picked repository.
  const pick = useCallback(async (fullName, { typed = false } = {}) => {
    setError(null);
    setTypedNameError(null);
    setChecking(true);
    try {
      const query = `repository=${encodeURIComponent(fullName)}`;
      const res = await fetch(`/api/projects/preflight?${query}`);
      const data = await res.json().catch(() => ({}));
      if (data.reconnect_required) {
        setReconnectRequired(true);
        return;
      }
      if (!res.ok) {
        const message = apiErrorMessage(data, `Could not check ${fullName} (HTTP ${res.status}).`);
        if (typed) setTypedNameError(message); else setError(message);
        return;
      }
      setSelected(data.repository.full_name);
      setPreflight(data.preflight);
      setName((current) => projectNameAfterPick({ name: current, edited: nameEdited, fullName: data.repository.full_name }));
      setRows([]);
      if (data.preflight.status === 'unsupported') return;

      const found = await fetch(`/api/projects/discover_secrets?${query}`);
      const discovery = await found.json().catch(() => ({}));
      if (!found.ok) throw new Error(apiErrorMessage(discovery, `Could not read ${fullName}'s environment variables (HTTP ${found.status}).`));
      setRows(secretRows(discovery.variables || []));
    } catch (e) {
      setError(e.message);
    } finally {
      setChecking(false);
    }
  }, [nameEdited]);

  const create = async () => {
    setCreating(true);
    setError(null);
    try {
      const res = await fetch('/api/projects', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ repository: selected, name, start_url: startUrl, secrets: secretsPayload(rows) }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `Could not create the project (HTTP ${res.status}).`));
      onCreated(data.project);
    } catch (e) {
      setError(e.message);
    } finally {
      setCreating(false);
    }
  };

  const github = capabilities?.github;
  const pickerState = repoPickerState({ github, repositories, reconnectRequired, pendingApproval: github?.pending_approval === true });
  const problem = checking ? 'Checking the repository…' : createProblem({ capabilities, preflight, secretsProblem: secretsFormProblem(rows) });

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }} data-testid="new-project">
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 16 }}>
        <div style={{ flex: 1 }}>
          <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>New project</h1>
          <p style={{ margin: '4px 0 0', fontSize: 14, color: 'var(--color-text-secondary)' }}>
            Boot a repository in a sandbox, installing the engine there when it does not have it, and evaluate an agent against the running app.
          </p>
        </div>
        <Button onClick={onCancel}>Cancel</Button>
      </div>

      {error && (
        <div style={{ padding: '10px 12px', borderRadius: 8, fontSize: 13, background: 'var(--color-error-soft)', color: 'var(--color-error-text)' }}>{error}</div>
      )}

      {capabilities && <CapabilitiesChecklist capabilities={capabilities} />}

      <Card>
        <MicroLabel>Repository</MicroLabel>
        <div style={{ marginTop: 8 }}>
          <RepoPicker
            mode="single"
            state={pickerState}
            repositories={repositories || []}
            filter={filter}
            onFilterChange={setFilter}
            selected={selected}
            onSelect={(fullName) => pick(fullName)}
            settingsHref={dashboardPath('/settings?tab=integrations')}
            missingRepositoryUrl={github?.access_settings_url}
            onRefresh={() => loadRepositories().catch((e) => setError(e.message))}
            onTypeName={(fullName) => pick(fullName, { typed: true })}
            typedNameError={typedNameError}
          />
        </div>
        {preflight && <div style={{ marginTop: 12 }}><PreflightResult repository={selected} preflight={preflight} /></div>}
      </Card>

      {preflight && preflight.status !== 'unsupported' && (
        <Card>
          <MicroLabel>Project</MicroLabel>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginTop: 8 }}>
            <label style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>
              Name
              <input
                type="text"
                value={name}
                onChange={(event) => {
                  setName(event.target.value);
                  setNameEdited(event.target.value !== '');
                }}
                style={{ ...fieldStyle, marginTop: 4 }}
              />
            </label>
            <label style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>
              Start URL (must not answer 5xx once booted)
              <input type="text" value={startUrl} onChange={(event) => setStartUrl(event.target.value)} style={{ ...fieldStyle, marginTop: 4, fontFamily: MONO }} />
            </label>
          </div>
          <div style={{ marginTop: 16 }}>
            <MicroLabel>Secrets the boot needs</MicroLabel>
            <div style={{ marginTop: 8 }}>
              <ProjectSecretsForm rows={rows} onChange={setRows} repository={selected} />
            </div>
          </div>
        </Card>
      )}

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, justifyContent: 'flex-end' }}>
        {problem && <span data-testid="create-problem" style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>{problem}</span>}
        <Button variant="primary" onClick={create} disabled={Boolean(problem) || creating} testId="create-project">
          {creating ? 'Creating…' : 'Create project'}
        </Button>
      </div>
    </div>
  );
}
