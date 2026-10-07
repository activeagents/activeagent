import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Button, Card } from './primitives';
import { navigateTo } from '../../utils/dashboardPath';
import { apiErrorMessage } from '../../utils/codeSessions.mjs';

// /catalogs: the owner's scenario catalogs. A catalog is a YAML document of
// products (an agent or a project under test), each with named sets of
// scenarios. It is imported here from pasted YAML or from a connected
// repository at a ref (a pull request's branch), exported back as YAML, kept
// in Active Storage when the host has it, and run one set at a time: the
// set becomes an evaluation of the agent under test, run against the
// project's booted app and browser when a project is chosen.
export default function ScenarioCatalogsView({ visit = 0 }) {
  const [catalogs, setCatalogs] = useState(null);
  const [storageAvailable, setStorageAvailable] = useState(false);
  const [selected, setSelected] = useState(null);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState(null);
  const [agents, setAgents] = useState([]);
  const [projects, setProjects] = useState([]);
  const [importing, setImporting] = useState(false);
  const [showImport, setShowImport] = useState(false);

  const load = useCallback(async () => {
    try {
      const res = await fetch('/api/scenario_catalogs');
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `Could not list catalogs (HTTP ${res.status}).`));
      setCatalogs(data.catalogs || []);
      setStorageAvailable(data.storage_available === true);
      setError(null);
    } catch (e) {
      setError(e.message);
    }
  }, []);

  const loadTargets = useCallback(async () => {
    try {
      const [agentsRes, projectsRes] = await Promise.all([fetch('/api/agents'), fetch('/api/projects')]);
      const agentData = await agentsRes.json().catch(() => ({}));
      const projectData = await projectsRes.json().catch(() => ({}));
      setAgents((agentData.agents || []).filter((agent) => !agent.observed));
      setProjects(projectData.projects || []);
    } catch (e) {
      // Targets are a convenience for the run form; the list still renders.
    }
  }, []);

  useEffect(() => {
    load();
    loadTargets();
  }, [load, loadTargets, visit]);

  const open = useCallback(async (id) => {
    try {
      const res = await fetch(`/api/scenario_catalogs/${id}`);
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `Could not open the catalog (HTTP ${res.status}).`));
      setSelected(data.catalog);
      setError(null);
    } catch (e) {
      setError(e.message);
    }
  }, []);

  const refreshSelected = useCallback(async () => {
    await load();
    if (selected) await open(selected.id);
  }, [load, open, selected]);

  const importCatalog = async (payload) => {
    setImporting(true);
    setError(null);
    try {
      const res = await fetch('/api/scenario_catalogs', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `Import refused (HTTP ${res.status}).`));
      const imported = data.catalogs || [];
      setNotice(`Imported ${imported.map((catalog) => catalog.key).join(', ') || 'nothing'}.`);
      setShowImport(false);
      await load();
      if (imported.length === 1) setSelected(imported[0]);
    } catch (e) {
      setError(e.message);
    } finally {
      setImporting(false);
    }
  };

  const sync = async (catalog, direction) => {
    setError(null);
    try {
      const res = await fetch(`/api/scenario_catalogs/${catalog.id}/sync`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ direction }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `Sync failed (HTTP ${res.status}).`));
      setSelected(data.catalog);
      setNotice(direction === 'pull' ? 'Catalog restored from storage.' : 'Catalog written to storage.');
      await load();
    } catch (e) {
      setError(e.message);
    }
  };

  const remove = async (catalog) => {
    if (!window.confirm(`Delete the catalog ${catalog.key}? Its evaluations and their runs stay.`)) return;
    try {
      const res = await fetch(`/api/scenario_catalogs/${catalog.id}`, { method: 'DELETE' });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(apiErrorMessage(data, `Delete failed (HTTP ${res.status}).`));
      }
      setSelected(null);
      await load();
    } catch (e) {
      setError(e.message);
    }
  };

  const runSet = async (catalog, set, target) => {
    setError(null);
    setNotice(null);
    try {
      const res = await fetch(`/api/scenario_catalogs/${catalog.id}/sets/${set.id}/run`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(target),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `The run could not start (HTTP ${res.status}).`));
      setNotice(`Run #${data.run.id} of ${set.name} started; it shows under Evaluations as ${data.evaluation.name}.`);
      await refreshSelected();
    } catch (e) {
      setError(e.message);
    }
  };

  if (selected) {
    return (
      <CatalogDetail
        catalog={selected}
        agents={agents}
        projects={projects}
        storageAvailable={storageAvailable}
        error={error}
        notice={notice}
        onBack={() => { setSelected(null); setNotice(null); setError(null); }}
        onRun={runSet}
        onSync={sync}
        onDelete={remove}
        onReimport={(document) => importCatalog({ document })}
      />
    );
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
        <div>
          <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>Scenario catalogs</h1>
          <p style={{ margin: '4px 0 0', fontSize: 14, color: 'var(--color-text-secondary)' }}>
            Scenarios kept as YAML, by product and set, imported from a document or a repository and run as evaluations.
          </p>
        </div>
        <Button onClick={() => setShowImport((value) => !value)}>{showImport ? 'Close' : 'Import catalog'}</Button>
      </div>

      {error && <Notice tone="error">{error}</Notice>}
      {notice && <Notice>{notice}</Notice>}

      {showImport && <ImportForm importing={importing} onImport={importCatalog} />}

      {catalogs === null ? (
        <p style={{ color: 'var(--color-text-secondary)' }}>Loading…</p>
      ) : catalogs.length === 0 ? (
        <Card>
          <p style={{ margin: 0, color: 'var(--color-text-secondary)' }}>
            No catalogs yet. Import a YAML document, or read the <code>.activeagents/evals</code> directory of a connected repository.
          </p>
        </Card>
      ) : (
        <div style={{ display: 'grid', gap: 12 }}>
          {catalogs.map((catalog) => (
            <Card key={catalog.id} style={{ cursor: 'pointer' }} onClick={() => open(catalog.id)}>
              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
                <div>
                  <div style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{catalog.name}</div>
                  <div style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>
                    <code>{catalog.key}</code>
                    {catalog.source_path ? ` · ${catalog.source_path}` : ` · ${catalog.source_kind}`}
                  </div>
                </div>
                <div style={{ fontSize: 13, color: 'var(--color-text-secondary)', textAlign: 'right' }}>
                  {catalog.product_count} {catalog.product_count === 1 ? 'product' : 'products'} · {catalog.scenario_count} scenarios
                  <div>{catalog.synced ? 'synced to storage' : storageAvailable ? 'not synced' : 'database only'}</div>
                </div>
              </div>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}

function ImportForm({ importing, onImport }) {
  const [mode, setMode] = useState('document');
  const [document, setDocument] = useState('');
  const [repository, setRepository] = useState('');
  const [ref, setRef] = useState('');
  const [path, setPath] = useState('.activeagents/evals');

  const submit = (event) => {
    event.preventDefault();
    if (mode === 'repository') {
      onImport({ repository: repository.trim(), ref: ref.trim() || undefined, path: path.trim() || undefined });
    } else {
      onImport({ document });
    }
  };

  return (
    <Card>
      <form onSubmit={submit} style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <div style={{ display: 'flex', gap: 8 }}>
          <Button type="button" size="sm" variant={mode === 'document' ? 'primary' : 'ghost'} onClick={() => setMode('document')}>Paste YAML</Button>
          <Button type="button" size="sm" variant={mode === 'repository' ? 'primary' : 'ghost'} onClick={() => setMode('repository')}>From a repository</Button>
        </div>
        {mode === 'document' ? (
          <textarea
            value={document}
            onChange={(event) => setDocument(event.target.value)}
            rows={12}
            placeholder={'catalog: support_desk\nproducts:\n  - key: triage\n    agent: TriageAgent\n    sets:\n      - key: smoke\n        scenarios:\n          - key: refund\n            prompt: A customer asks for a refund.\n            expect: { tools: [lookup_order] }'}
            style={{ fontFamily: 'var(--font-mono, monospace)', fontSize: 12, padding: 8, borderRadius: 6, border: '1px solid var(--color-border)', background: 'var(--color-surface)', color: 'var(--color-text-primary)' }}
          />
        ) : (
          <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))' }}>
            <Field label="Repository" value={repository} onChange={setRepository} placeholder="owner/name" />
            <Field label="Ref" value={ref} onChange={setRef} placeholder="a branch, tag or commit; the default branch when empty" />
            <Field label="Path" value={path} onChange={setPath} placeholder=".activeagents/evals or one .yml file" />
          </div>
        )}
        <div>
          <Button type="submit" disabled={importing || (mode === 'document' ? !document.trim() : !repository.trim())}>
            {importing ? 'Importing…' : 'Import'}
          </Button>
        </div>
      </form>
    </Card>
  );
}

function Field({ label, value, onChange, placeholder }) {
  return (
    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12, color: 'var(--color-text-secondary)' }}>
      {label}
      <input
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder={placeholder}
        style={{ padding: 6, borderRadius: 6, border: '1px solid var(--color-border)', background: 'var(--color-surface)', color: 'var(--color-text-primary)', fontSize: 13 }}
      />
    </label>
  );
}

function CatalogDetail({ catalog, agents, projects, storageAvailable, error, notice, onBack, onRun, onSync, onDelete, onReimport }) {
  const [editing, setEditing] = useState(false);
  const [document, setDocument] = useState('');

  const exportUrl = useMemo(() => `/api/scenario_catalogs/${catalog.id}/export`, [catalog.id]);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
        <Button size="sm" variant="ghost" onClick={onBack} style={{ padding: 0 }}>← Catalogs</Button>
      </div>
      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap', alignItems: 'flex-start' }}>
        <div>
          <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>{catalog.name}</h1>
          <p style={{ margin: '4px 0 0', fontSize: 13, color: 'var(--color-text-secondary)' }}>
            <code>{catalog.key}</code>
            {catalog.source_path ? ` · ${catalog.source_path}` : ''}
            {catalog.description ? ` · ${catalog.description}` : ''}
          </p>
          <p style={{ margin: '4px 0 0', fontSize: 12, color: 'var(--color-text-secondary)' }}>
            digest {catalog.digest ? catalog.digest.slice(0, 12) : '—'} ·{' '}
            {catalog.synced ? `synced to storage ${catalog.synced_at ? new Date(catalog.synced_at).toLocaleString() : ''}` : storageAvailable ? 'not synced to storage' : 'Active Storage is off for this dashboard'}
          </p>
        </div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          <Button size="sm" variant="ghost" onClick={() => window.open(exportUrl, '_blank')}>Export YAML</Button>
          {storageAvailable && <Button size="sm" variant="ghost" onClick={() => onSync(catalog, 'push')}>Write to storage</Button>}
          {storageAvailable && catalog.synced_at && <Button size="sm" variant="ghost" onClick={() => onSync(catalog, 'pull')}>Restore from storage</Button>}
          <Button size="sm" variant="ghost" onClick={() => setEditing((value) => !value)}>{editing ? 'Cancel' : 'Re-import YAML'}</Button>
          <Button size="sm" variant="ghost" onClick={() => onDelete(catalog)}>Delete</Button>
        </div>
      </div>

      {error && <Notice tone="error">{error}</Notice>}
      {notice && <Notice>{notice}</Notice>}

      {editing && (
        <Card>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <textarea
              value={document}
              onChange={(event) => setDocument(event.target.value)}
              rows={14}
              placeholder="Paste the catalog document; its products, sets and scenarios replace this catalog's."
              style={{ fontFamily: 'var(--font-mono, monospace)', fontSize: 12, padding: 8, borderRadius: 6, border: '1px solid var(--color-border)', background: 'var(--color-surface)', color: 'var(--color-text-primary)' }}
            />
            <div>
              <Button size="sm" disabled={!document.trim()} onClick={() => { onReimport(document); setEditing(false); }}>Import</Button>
            </div>
          </div>
        </Card>
      )}

      {(catalog.products || []).map((product) => (
        <Card key={product.id}>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
            <div>
              <div style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{product.name}</div>
              <div style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>
                <code>{product.key}</code>
                {product.agent ? ` · agent ${product.agent.name}` : product.agent_name ? ` · agent ${product.agent_name} (not on this dashboard)` : ''}
                {product.project ? ` · project ${product.project.name} (${product.project.repository}${product.project.ref ? `@${product.project.ref}` : ''})` : ''}
              </div>
              {product.description && <p style={{ margin: '4px 0 0', fontSize: 13, color: 'var(--color-text-secondary)' }}>{product.description}</p>}
            </div>
            <div style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>{product.set_count} sets · {product.scenario_count} scenarios</div>
          </div>
          <div style={{ display: 'grid', gap: 8, marginTop: 12 }}>
            {(product.sets || []).map((set) => (
              <SetRow key={set.id} catalog={catalog} product={product} set={set} agents={agents} projects={projects} onRun={onRun} />
            ))}
          </div>
        </Card>
      ))}
    </div>
  );
}

function SetRow({ catalog, product, set, agents, projects, onRun }) {
  const defaultTarget = product.project ? `project:${product.project.id}` : product.agent ? `agent:${product.agent.id}` : '';
  const [target, setTarget] = useState(defaultTarget);
  const [expanded, setExpanded] = useState(false);

  const run = () => {
    const [kind, id] = target.split(':');
    const payload = kind === 'project' ? { project_id: Number(id) } : kind === 'agent' ? { agent_id: Number(id) } : {};
    onRun(catalog, set, payload);
  };

  return (
    <div style={{ border: '1px solid var(--color-border)', borderRadius: 8, padding: 10 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap', alignItems: 'center' }}>
        <div>
          <span style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{set.name}</span>{' '}
          <code style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>{set.key}</code>
          <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}> · {set.scenario_count} scenarios</span>
          {set.evaluation && (
            <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>
              {' · '}
              <a href="#" onClick={(event) => { event.preventDefault(); navigateTo(`/evaluations/${set.evaluation.id}`); }}>
                evaluation {set.evaluation.name}
              </a>
              {set.latest_run ? ` (latest run ${set.latest_run.status})` : ''}
            </span>
          )}
        </div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          <select
            value={target}
            onChange={(event) => setTarget(event.target.value)}
            style={{ fontSize: 12, padding: 4, borderRadius: 6, border: '1px solid var(--color-border)', background: 'var(--color-surface)', color: 'var(--color-text-primary)' }}
          >
            <option value="">Run against…</option>
            {projects.length > 0 && (
              <optgroup label="Projects (booted app and browser)">
                {projects.map((project) => (
                  <option key={`project-${project.id}`} value={`project:${project.id}`}>
                    {project.name} ({project.repository}{project.ref ? `@${project.ref}` : ''})
                  </option>
                ))}
              </optgroup>
            )}
            {agents.length > 0 && (
              <optgroup label="Agents">
                {agents.map((agent) => (
                  <option key={`agent-${agent.id}`} value={`agent:${agent.id}`}>{agent.name}</option>
                ))}
              </optgroup>
            )}
          </select>
          <Button size="sm" onClick={run} disabled={!target && !product.agent && !product.project}>Run set</Button>
          <Button size="sm" variant="ghost" onClick={() => setExpanded((value) => !value)}>{expanded ? 'Hide' : 'Scenarios'}</Button>
        </div>
      </div>
      {expanded && (
        <ol style={{ margin: '10px 0 0', paddingLeft: 20, display: 'grid', gap: 6 }}>
          {(set.scenarios || []).map((scenario) => (
            <li key={scenario.id} style={{ fontSize: 13, color: 'var(--color-text-primary)' }}>
              <code style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>{scenario.key}</code> {scenario.prompt}
              {scenario.tags && scenario.tags.length > 0 && (
                <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}> · {scenario.tags.join(', ')}</span>
              )}
              {scenario.production_only && <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}> · production only</span>}
              {!scenario.enabled && <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}> · disabled</span>}
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}

function Notice({ tone = 'info', children }) {
  const color = tone === 'error' ? 'var(--color-danger, #b91c1c)' : 'var(--color-text-secondary)';
  return (
    <div role={tone === 'error' ? 'alert' : 'status'} style={{ fontSize: 13, color, padding: '8px 10px', border: '1px solid var(--color-border)', borderRadius: 8 }}>
      {children}
    </div>
  );
}
