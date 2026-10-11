import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Button, Card, Hint, Menu, MonoLink, PageHeader, TABLE, MONO } from './primitives';
import { dashboardPath, navigateTo } from '../../utils/dashboardPath';
import { apiErrorMessage } from '../../utils/codeSessions.mjs';
import { timeAgo } from '../../utils/format';

// /catalogs: the owner's scenario catalogs. A catalog is a YAML document of
// products (an agent or a project under test), each with named sets of
// scenarios. It is imported here from pasted YAML or from a connected
// repository at a ref (a pull request's branch), exported back as YAML, kept
// in Active Storage when the host has it, and run one set at a time: the
// set becomes an evaluation of the agent under test, run against the
// project's booted app and browser when a project is chosen.
//
// embedded: the host (the Evaluations page's Catalogs tab) carries the
// title, so the list renders its toolbar alone.
export default function ScenarioCatalogsView({ visit = 0, embedded = false }) {
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

  const importButton = <Button onClick={() => setShowImport((value) => !value)}>{showImport ? 'Close' : 'Import catalog'}</Button>;
  const storageText = (catalog) => (catalog.synced ? 'synced' : storageAvailable ? 'not synced' : 'database only');

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      {embedded ? (
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, flexWrap: 'wrap' }}>{importButton}</div>
      ) : (
        <PageHeader title="Scenario catalogs" actions={importButton} />
      )}

      {error && <Notice tone="error">{error}</Notice>}
      {notice && <Notice>{notice}</Notice>}

      {showImport && <ImportForm importing={importing} onImport={importCatalog} />}

      {catalogs === null ? (
        <p style={{ margin: 0, color: 'var(--color-text-secondary)' }}>Loading…</p>
      ) : (
        <div style={TABLE.frame}>
          <table style={TABLE.table} data-testid="catalogs-table">
            <thead>
              <tr>
                <th scope="col" style={TABLE.th}>Catalog</th>
                <th scope="col" style={{ ...TABLE.th, ...TABLE.right }}>Products</th>
                <th scope="col" style={{ ...TABLE.th, ...TABLE.right }}>Scenarios</th>
                <th scope="col" style={TABLE.th}>Storage</th>
              </tr>
            </thead>
            <tbody>
              {catalogs.length === 0 && (
                <tr>
                  <td colSpan={4} style={{ ...TABLE.td, borderBottom: 'none', padding: '32px 14px', textAlign: 'center' }}>
                    <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--color-text-primary)' }}>No catalogs yet</div>
                    <p style={{ margin: '4px 0 0', fontSize: 12, color: 'var(--color-text-muted)' }}>
                      Import a YAML document, or read the <span style={{ fontFamily: MONO }}>.activeagents/evals</span> directory of a connected repository.
                    </p>
                  </td>
                </tr>
              )}
              {catalogs.map((catalog, index) => {
                const last = index === catalogs.length - 1;
                const cell = (extra) => ({ ...TABLE.td, ...(last ? { borderBottom: 'none' } : {}), ...extra });
                return (
                  <tr
                    key={catalog.id}
                    className="aa-row"
                    data-testid="catalog-row"
                    tabIndex={0}
                    onClick={() => open(catalog.id)}
                    onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(catalog.id); } }}
                    style={{ cursor: 'pointer' }}
                  >
                    <td style={cell()}>
                      <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--color-text-primary)' }}>{catalog.name}</div>
                      <div style={{ ...TABLE.mono, color: 'var(--color-text-muted)' }}>
                        {catalog.key}
                        {catalog.source_path ? ` · ${catalog.source_path}` : catalog.source_kind ? ` · ${catalog.source_kind}` : ''}
                      </div>
                    </td>
                    <td style={cell({ ...TABLE.mono, ...TABLE.right })}>{catalog.product_count}</td>
                    <td style={cell({ ...TABLE.mono, ...TABLE.right })}>{catalog.scenario_count}</td>
                    <td style={cell({ ...TABLE.mono, color: 'var(--color-text-muted)' })}>{storageText(catalog)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

const fieldStyle = {
  padding: '6px 10px', borderRadius: 8, border: '1px solid var(--color-border)', background: 'var(--color-surface)',
  color: 'var(--color-text-primary)', fontSize: 13, fontFamily: 'inherit',
};

const yamlStyle = {
  fontFamily: MONO, fontSize: 12, padding: 8, borderRadius: 8, border: '1px solid var(--color-border)',
  background: 'var(--color-surface)', color: 'var(--color-text-primary)',
};

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
            aria-label="Catalog YAML"
            value={document}
            onChange={(event) => setDocument(event.target.value)}
            rows={12}
            placeholder={'catalog: support_desk\nproducts:\n  - key: triage\n    agent: TriageAgent\n    sets:\n      - key: smoke\n        scenarios:\n          - key: refund\n            prompt: A customer asks for a refund.\n            expect: { tools: [lookup_order] }'}
            style={yamlStyle}
          />
        ) : (
          <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))' }}>
            <Field label="Repository" value={repository} onChange={setRepository} placeholder="owner/name" />
            <Field label="Ref" value={ref} onChange={setRef} placeholder="a branch, tag or commit; the default branch when empty" />
            <Field label="Path" value={path} onChange={setPath} placeholder=".activeagents/evals or one .yml file" />
          </div>
        )}
        <div>
          <Button type="submit" variant="primary" disabled={importing || (mode === 'document' ? !document.trim() : !repository.trim())}>
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
      <input value={value} onChange={(event) => onChange(event.target.value)} placeholder={placeholder} style={fieldStyle} />
    </label>
  );
}

// A scenario's expectations, as the catalog recorded them ({ tools,
// contains, not_contains }), in one mono line: "calls lookup_order · says
// “refund” · never says “unfortunately”". Empty when it expects nothing.
export const expectationSummary = (expectations) => {
  const value = expectations && typeof expectations === 'object' ? expectations : {};
  const list = (key) => (Array.isArray(value[key]) ? value[key] : value[key] ? [value[key]] : []).map(String);
  return [
    ...list('tools').map((tool) => `calls ${tool}`),
    ...list('contains').map((text) => `says “${text}”`),
    ...list('not_contains').map((text) => `never says “${text}”`),
  ].join(' · ');
};

// The agent a product names: the dashboard's agent, else the name the
// document gave (not on this dashboard), else the project under test.
const productAgentName = (product) => product.agent?.name || product.agent_name || product.project?.name || '—';

function CatalogDetail({ catalog, agents, projects, storageAvailable, error, notice, onBack, onRun, onSync, onDelete, onReimport }) {
  const [editing, setEditing] = useState(false);
  const [document, setDocument] = useState('');

  const exportUrl = useMemo(() => `/api/scenario_catalogs/${catalog.id}/export`, [catalog.id]);

  const meta = [
    catalog.key,
    catalog.source_path,
    catalog.synced_at ? `synced ${timeAgo(catalog.synced_at)}` : 'not synced',
  ].filter(Boolean).join(' · ');

  const menuItems = [
    { label: 'Export YAML', onClick: () => window.open(exportUrl, '_blank') },
    ...(storageAvailable && catalog.synced_at ? [{ label: 'Restore from storage', onClick: () => onSync(catalog, 'pull') }] : []),
    { label: editing ? 'Cancel re-import' : 'Re-import YAML', onClick: () => setEditing((value) => !value) },
    { label: 'Delete', tone: 'danger', onClick: () => onDelete(catalog) },
  ];

  const sets = (catalog.products || []).flatMap((product) => (product.sets || []).map((set) => ({ product, set })));

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      <PageHeader
        crumbs={[
          { label: 'Evaluations', onClick: () => navigateTo('/evaluations') },
          { label: 'Catalogs', onClick: onBack, testId: 'catalogs-crumb' },
        ]}
        title={catalog.name}
        meta={meta}
        actions={(
          <>
            {storageAvailable && <Button onClick={() => onSync(catalog, 'push')}>Write to storage</Button>}
            <Menu glyph="..." ariaLabel="More: export YAML, restore, re-import, delete" items={menuItems} testId="catalog-menu" />
          </>
        )}
      />

      {error && <Notice tone="error">{error}</Notice>}
      {notice && <Notice>{notice}</Notice>}

      {editing && (
        <Card>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <textarea
              aria-label="Catalog YAML"
              value={document}
              onChange={(event) => setDocument(event.target.value)}
              rows={14}
              placeholder="Paste the catalog document; its products, sets and scenarios replace this catalog's."
              style={yamlStyle}
            />
            <div>
              <Button size="sm" variant="primary" disabled={!document.trim()} onClick={() => { onReimport(document); setEditing(false); }}>Import</Button>
            </div>
          </div>
        </Card>
      )}

      <div style={TABLE.frame}>
        <table style={{ ...TABLE.table, minWidth: 900 }} data-testid="catalog-sets-table">
          <thead>
            <tr>
              <th scope="col" style={TABLE.th}>Set</th>
              <th scope="col" style={TABLE.th}>Product · agent</th>
              <th scope="col" style={{ ...TABLE.th, ...TABLE.right }}>Scenarios</th>
              <th scope="col" style={TABLE.th}>Latest run</th>
              <th scope="col" style={TABLE.th}>Run against</th>
              <th scope="col" style={TABLE.th} aria-label="Run" />
            </tr>
          </thead>
          <tbody>
            {sets.length === 0 && (
              <tr>
                <td colSpan={6} style={{ ...TABLE.td, borderBottom: 'none', padding: '32px 14px', textAlign: 'center' }}>
                  <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--color-text-primary)' }}>No sets in this catalog</div>
                </td>
              </tr>
            )}
            {sets.map(({ product, set }, index) => (
              <SetRow
                key={set.id}
                catalog={catalog}
                product={product}
                set={set}
                agents={agents}
                projects={projects}
                onRun={onRun}
                last={index === sets.length - 1}
              />
            ))}
          </tbody>
        </table>
      </div>
      <Hint>
        Running a set creates or reuses the evaluation <span style={{ fontFamily: MONO }}>{`${catalog.key}/<product>/<set>`}</span>.
      </Hint>
    </div>
  );
}

const selectStyle = {
  minHeight: 32, padding: '0 8px', borderRadius: 8, border: '1px solid var(--color-border)', background: 'var(--color-surface)',
  color: 'var(--color-text-primary)', fontFamily: 'inherit', fontSize: 12, maxWidth: '100%',
};

const RUN_COLOR = { failed: 'var(--color-error-text)', running: 'var(--color-info-text)', pending: 'var(--color-info-text)' };

// One set: its row, and under it, when open, its scenarios.
function SetRow({ catalog, product, set, agents, projects, onRun, last }) {
  const defaultTarget = product.project ? `project:${product.project.id}` : product.agent ? `agent:${product.agent.id}` : '';
  const [target, setTarget] = useState(defaultTarget);
  const [expanded, setExpanded] = useState(false);

  const run = () => {
    const [kind, id] = target.split(':');
    const payload = kind === 'project' ? { project_id: Number(id) } : kind === 'agent' ? { agent_id: Number(id) } : {};
    onRun(catalog, set, payload);
  };

  const toggle = () => setExpanded((value) => !value);
  const stop = (event) => event.stopPropagation();
  const bottom = last && !expanded ? { borderBottom: 'none' } : {};
  const cell = (extra) => ({ ...TABLE.td, ...bottom, ...extra });
  const latest = set.latest_run;
  const runPath = latest && set.evaluation ? `/evaluations/${set.evaluation.id}/runs/${latest.id}` : null;
  const scenarios = set.scenarios || [];

  return (
    <>
      <tr
        className="aa-row"
        data-testid="catalog-set-row"
        data-open={expanded ? 'true' : 'false'}
        onClick={toggle}
        style={{ cursor: 'pointer' }}
      >
        <td style={cell()}>
          <button
            type="button"
            aria-expanded={expanded}
            onClick={(event) => { event.stopPropagation(); toggle(); }}
            style={{ display: 'block', background: 'none', border: 0, padding: 0, fontFamily: 'inherit', fontSize: 13, fontWeight: 500, color: 'var(--color-text-primary)', textAlign: 'left', cursor: 'pointer' }}
          >
            {set.name}
          </button>
          {set.description && <div style={{ fontSize: 12, color: 'var(--color-text-muted)' }}>{set.description}</div>}
        </td>
        <td style={cell({ color: 'var(--color-text-secondary)' })}>
          {product.name} · <span style={TABLE.mono}>{productAgentName(product)}</span>
        </td>
        <td style={cell({ ...TABLE.mono, ...TABLE.right })}>{set.scenario_count ?? scenarios.length}</td>
        <td style={cell()} onClick={stop}>
          {latest && runPath ? (
            <MonoLink size={12} href={dashboardPath(runPath)} onClick={() => navigateTo(runPath)} color={RUN_COLOR[latest.status] || 'var(--color-info)'}>
              {`${latest.status} · ${timeAgo(latest.created_at)}`}
            </MonoLink>
          ) : (
            <span style={{ ...TABLE.mono, color: 'var(--color-text-muted)' }}>never run</span>
          )}
        </td>
        <td style={cell()} onClick={stop}>
          <select aria-label="Run against" value={target} onChange={(event) => setTarget(event.target.value)} style={selectStyle}>
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
        </td>
        <td style={cell(TABLE.right)} onClick={stop}>
          <Button size="sm" onClick={run} disabled={!target && !product.agent && !product.project}>Run set</Button>
        </td>
      </tr>
      {expanded && (
        <tr data-testid="catalog-set-scenarios">
          <td colSpan={6} style={{ padding: '4px 14px 14px', background: 'var(--color-background)', borderBottom: last ? 'none' : '1px solid var(--color-border-light)' }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {scenarios.length === 0 && <span style={{ ...TABLE.mono, color: 'var(--color-text-muted)' }}>no scenarios</span>}
              {scenarios.map((scenario) => {
                const flags = [
                  ...(scenario.tags || []),
                  scenario.production_only ? 'production only' : null,
                  scenario.enabled === false ? 'disabled' : null,
                ].filter(Boolean);
                return (
                  <div key={scenario.id || scenario.key} style={{ display: 'flex', flexWrap: 'wrap', gap: 10, alignItems: 'center', padding: '8px 10px', borderRadius: 8, background: 'var(--color-surface)', border: '1px solid var(--color-border-light)' }}>
                    <span style={{ ...TABLE.mono, color: 'var(--color-text-muted)', width: 140, flexShrink: 0 }}>{scenario.key}</span>
                    <span style={{ flex: 1, minWidth: 200, color: 'var(--color-text-primary)' }}>{scenario.prompt}</span>
                    <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-secondary)' }}>
                      {[expectationSummary(scenario.expectations), ...flags].filter(Boolean).join(' · ')}
                    </span>
                  </div>
                );
              })}
            </div>
          </td>
        </tr>
      )}
    </>
  );
}

function Notice({ tone = 'info', children }) {
  const color = tone === 'error' ? 'var(--color-error-text)' : 'var(--color-text-secondary)';
  return (
    <div role={tone === 'error' ? 'alert' : 'status'} style={{ fontSize: 13, color, padding: '8px 10px', border: '1px solid var(--color-border)', borderRadius: 8 }}>
      {children}
    </div>
  );
}
