import React, { useCallback, useEffect, useState } from 'react';
import { Badge, Button, Card, MONO } from '../primitives';
import { Check, Field, Notice, Select } from './fields';
import { requestJson, requestText } from './request';
import { navigateTo } from '../../../utils/dashboardPath';
import { copyToClipboard } from '../../../utils/clipboard.mjs';
import {
  expectationText, exportUrl, scenarioForm, scenarioFormProblem, scenarioPayload, toggleId,
} from '../../../utils/scenarios.mjs';
import { requestConfirm } from '../../../utils/confirm.mjs';

// One collection (a scenario catalog): its products, their sets and the
// sets' scenarios, each edited in place. Every change goes through the
// catalog entries API, which checks it as an import would and rewrites the
// collection's YAML. Checked scenarios, sets and products export as a YAML
// document of this collection, which a merge import reads back without
// touching the rest; Export all writes the whole of it.
export default function ScenarioCollection({ collectionId, agents, projects, storageAvailable, onBack, onChanged, onDeleted }) {
  const [collection, setCollection] = useState(null);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState(null);
  const [selection, setSelection] = useState({ productIds: [], setIds: [], scenarioIds: [] });
  const [editingHeader, setEditingHeader] = useState(false);
  const [addingProduct, setAddingProduct] = useState(false);

  const base = `/api/scenario_catalogs/${collectionId}`;

  const load = useCallback(async () => {
    try {
      const data = await requestJson(base, { fallback: 'Could not open the collection' });
      setCollection(data.catalog);
      setError(null);
    } catch (e) {
      setError(e.message);
    }
  }, [base]);

  useEffect(() => { load(); }, [load]);

  // Sends a change and shows the collection the server answers with.
  // Throws, so a form can keep what was typed and show why.
  const change = async (path, method, body, fallback) => {
    const data = await requestJson(`${base}${path}`, { method, body, fallback });
    if (data.catalog) setCollection(data.catalog);
    else await load();
    onChanged?.();
    return data;
  };

  const act = async (fn) => {
    setError(null);
    setNotice(null);
    try {
      await fn();
    } catch (e) {
      setError(e.message);
    }
  };

  const selectedCount = selection.productIds.length + selection.setIds.length + selection.scenarioIds.length;
  const toggle = (kind, id) => setSelection((current) => ({ ...current, [kind]: toggleId(current[kind], id) }));

  const copyYaml = (chosen) => act(async () => {
    const yaml = await requestText(exportUrl(collectionId, chosen, { inline: true }));
    const copied = await copyToClipboard(yaml);
    setNotice(copied ? 'YAML copied.' : 'The browser refused the clipboard; use Download instead.');
  });
  const download = (chosen) => window.open(exportUrl(collectionId, chosen), '_blank');

  if (!collection) {
    return error ? <Notice tone="error">{error}</Notice> : <p style={{ color: 'var(--color-text-secondary)' }}>Loading the collection…</p>;
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }} data-testid="scenario-collection">
      <div>
        <Button size="sm" variant="ghost" onClick={onBack} style={{ padding: 0 }}>← Scenarios</Button>
      </div>

      {editingHeader ? (
        <HeaderForm
          collection={collection}
          onCancel={() => setEditingHeader(false)}
          onSave={async (attributes) => {
            await change('', 'PATCH', { catalog: attributes }, 'Could not save the collection');
            setEditingHeader(false);
          }}
        />
      ) : (
        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap', alignItems: 'flex-start' }}>
          <div>
            <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>{collection.name}</h1>
            <p style={{ margin: '4px 0 0', fontSize: 13, color: 'var(--color-text-secondary)' }}>
              <code>{collection.key}</code>
              {collection.source_path ? ` · ${collection.source_path}` : ''}
              {collection.description ? ` · ${collection.description}` : ''}
            </p>
            <p style={{ margin: '4px 0 0', fontSize: 12, color: 'var(--color-text-secondary)' }}>
              {collection.scenario_count} scenarios · digest {collection.digest ? collection.digest.slice(0, 12) : '—'} ·{' '}
              {collection.synced ? 'synced to storage' : storageAvailable ? 'not synced to storage' : 'Active Storage is off for this dashboard'}
            </p>
          </div>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <Button size="sm" variant="ghost" onClick={() => setEditingHeader(true)}>Rename</Button>
            <Button size="sm" variant="ghost" onClick={() => download({})} testId="scenarios-export-all">Export all</Button>
            <Button size="sm" variant="ghost" onClick={() => copyYaml({})}>Copy YAML</Button>
            {storageAvailable && (
              <Button size="sm" variant="ghost" onClick={() => act(async () => {
                await change('/sync', 'POST', { direction: 'push' }, 'Sync failed');
                setNotice('Written to storage.');
              })}>Write to storage</Button>
            )}
            <Button size="sm" variant="danger" onClick={() => act(async () => {
              if (!(await requestConfirm({ title: `Delete the collection ${collection.key}?`, message: 'Its products, sets and scenarios are deleted. The evaluations its sets became stay, with their runs.', confirmLabel: 'Delete collection', danger: true, requireText: collection.key }))) return;
              await requestJson(base, { method: 'DELETE', fallback: 'Delete failed' });
              onDeleted?.();
            })}>Delete</Button>
          </div>
        </div>
      )}

      {error && <Notice tone="error">{error}</Notice>}
      {notice && <Notice>{notice}</Notice>}

      {selectedCount > 0 && (
        <Card padding={12} testId="scenarios-selection-bar" style={{ position: 'sticky', top: 8, zIndex: 1 }}>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
            <span style={{ fontSize: 13, color: 'var(--color-text-primary)' }}>{selectedCount} selected</span>
            <Button size="sm" onClick={() => download(selection)} testId="scenarios-export-selection">Download YAML</Button>
            <Button size="sm" variant="ghost" onClick={() => copyYaml(selection)}>Copy YAML</Button>
            <Button size="sm" variant="ghost" onClick={() => setSelection({ productIds: [], setIds: [], scenarioIds: [] })}>Clear</Button>
            <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>
              Import it back with &ldquo;Keep what the document leaves out&rdquo; to update only these.
            </span>
          </div>
        </Card>
      )}

      {(collection.products || []).length === 0 && !addingProduct && (
        <Card testId="scenarios-collection-empty">
          <p style={{ margin: 0, color: 'var(--color-text-secondary)' }}>
            No products yet. A product is what its sets run against: an agent, or a project whose booted app the replays reach.
          </p>
        </Card>
      )}

      {(collection.products || []).map((product) => (
        <ProductCard
          key={product.id}
          product={product}
          collection={collection}
          agents={agents}
          projects={projects}
          selection={selection}
          onToggle={toggle}
          change={change}
          act={act}
          setNotice={setNotice}
        />
      ))}

      {addingProduct ? (
        <ProductForm
          agents={agents}
          projects={projects}
          onCancel={() => setAddingProduct(false)}
          onSave={async (attributes) => {
            await change('/products', 'POST', { product: attributes }, 'Could not add the product');
            setAddingProduct(false);
          }}
        />
      ) : (
        <div><Button size="sm" onClick={() => setAddingProduct(true)} testId="scenarios-add-product">Add product</Button></div>
      )}
    </div>
  );
}

function HeaderForm({ collection, onSave, onCancel }) {
  const [name, setName] = useState(collection.name || '');
  const [description, setDescription] = useState(collection.description || '');
  return (
    <SaveForm onSave={() => onSave({ name: name.trim(), description: description.trim() })} onCancel={onCancel}>
      <Field label="Name" value={name} onChange={setName} />
      <Field label="Description" value={description} onChange={setDescription} />
    </SaveForm>
  );
}

function ProductCard({ product, collection, agents, projects, selection, onToggle, change, act, setNotice }) {
  const [editing, setEditing] = useState(false);
  const [addingSet, setAddingSet] = useState(false);
  const path = `/products/${product.id}`;

  return (
    <Card testId="scenarios-product">
      {editing ? (
        <ProductForm
          product={product}
          agents={agents}
          projects={projects}
          onCancel={() => setEditing(false)}
          onSave={async (attributes) => {
            await change(path, 'PATCH', { product: attributes }, 'Could not save the product');
            setEditing(false);
          }}
        />
      ) : (
        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
          <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start' }}>
            <input type="checkbox" aria-label={`Select product ${product.key}`} checked={selection.productIds.includes(product.id)}
              onChange={() => onToggle('productIds', product.id)} style={{ marginTop: 4 }} />
            <div>
              <div style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{product.name}</div>
              <div style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>
                <code>{product.key}</code>
                {product.agent ? ` · agent ${product.agent.name}` : product.agent_name ? ` · agent ${product.agent_name} (not on this dashboard)` : ' · no agent chosen'}
                {product.project ? ` · project ${product.project.name}` : ''}
              </div>
              {product.description && <p style={{ margin: '4px 0 0', fontSize: 13, color: 'var(--color-text-secondary)' }}>{product.description}</p>}
            </div>
          </div>
          <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
            <span style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>{product.set_count} sets · {product.scenario_count} scenarios</span>
            <Button size="sm" variant="ghost" onClick={() => setEditing(true)}>Edit</Button>
            <Button size="sm" variant="danger" onClick={() => act(async () => {
              if (!(await requestConfirm({ title: `Delete product ${product.key}?`, message: `Its ${product.set_count} sets and their scenarios are deleted.`, confirmLabel: 'Delete product', danger: true }))) return;
              await change(path, 'DELETE', undefined, 'Could not delete the product');
            })}>Delete</Button>
          </div>
        </div>
      )}

      <div style={{ display: 'grid', gap: 8, marginTop: 12 }}>
        {(product.sets || []).map((set) => (
          <SetCard key={set.id} set={set} product={product} collection={collection} agents={agents} projects={projects}
            selection={selection} onToggle={onToggle} change={change} act={act} setNotice={setNotice} />
        ))}
        {addingSet ? (
          <SetForm
            onCancel={() => setAddingSet(false)}
            onSave={async (attributes) => {
              await change(`${path}/sets`, 'POST', { set: attributes }, 'Could not add the set');
              setAddingSet(false);
            }}
          />
        ) : (
          <div><Button size="sm" variant="ghost" onClick={() => setAddingSet(true)}>Add set</Button></div>
        )}
      </div>
    </Card>
  );
}

function SetCard({ set, product, collection, agents, projects, selection, onToggle, change, act, setNotice }) {
  const [expanded, setExpanded] = useState((set.scenarios || []).length <= 5);
  const [editing, setEditing] = useState(false);
  const [editingScenario, setEditingScenario] = useState(null); // a scenario id, or 'new'
  const defaultTarget = product.project ? `project:${product.project.id}` : product.agent ? `agent:${product.agent.id}` : '';
  const [target, setTarget] = useState(defaultTarget);
  const path = `/sets/${set.id}`;

  const run = () => act(async () => {
    const [kind, id] = target.split(':');
    const body = kind === 'project' ? { project_id: Number(id) } : kind === 'agent' ? { agent_id: Number(id) } : {};
    const data = await requestJson(`/api/scenario_catalogs/${collection.id}${path}/run`, { method: 'POST', body, fallback: 'The run could not start' });
    setNotice(`Run #${data.run.id} of ${set.name} started; it shows under Evaluations as ${data.evaluation.name}.`);
  });

  return (
    <div style={{ border: '1px solid var(--color-border)', borderRadius: 8, padding: 10 }} data-testid="scenarios-set">
      {editing ? (
        <SetForm
          set={set}
          onCancel={() => setEditing(false)}
          onSave={async (attributes) => {
            await change(path, 'PATCH', { set: attributes }, 'Could not save the set');
            setEditing(false);
          }}
        />
      ) : (
        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap', alignItems: 'center' }}>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
            <input type="checkbox" aria-label={`Select set ${set.key}`} checked={selection.setIds.includes(set.id)} onChange={() => onToggle('setIds', set.id)} />
            <span style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{set.name}</span>
            <code style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>{set.key}</code>
            <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>· {set.scenario_count} scenarios</span>
            {set.judge?.kind && <Badge>{`judge ${set.judge.kind}`}</Badge>}
            {set.evaluation && (
              <a href="#" style={{ fontSize: 12 }} onClick={(event) => { event.preventDefault(); navigateTo(`/evaluations/${set.evaluation.id}`); }}>
                evaluation{set.latest_run ? ` (latest run ${set.latest_run.status})` : ''}
              </a>
            )}
          </div>
          <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
            <select value={target} onChange={(event) => setTarget(event.target.value)}
              style={{ fontSize: 12, padding: 4, borderRadius: 6, border: '1px solid var(--color-border)', background: 'var(--color-surface)', color: 'var(--color-text-primary)' }}>
              <option value="">Run against…</option>
              {projects.length > 0 && (
                <optgroup label="Projects (booted app and browser)">
                  {projects.map((project) => <option key={`project-${project.id}`} value={`project:${project.id}`}>{project.name}</option>)}
                </optgroup>
              )}
              {agents.length > 0 && (
                <optgroup label="Agents">
                  {agents.map((agent) => <option key={`agent-${agent.id}`} value={`agent:${agent.id}`}>{agent.name}</option>)}
                </optgroup>
              )}
            </select>
            <Button size="sm" onClick={run} disabled={(!target && !product.agent && !product.project) || set.scenario_count === 0}>Run set</Button>
            <Button size="sm" variant="ghost" onClick={() => setExpanded((value) => !value)}>{expanded ? 'Hide' : 'Scenarios'}</Button>
            <Button size="sm" variant="ghost" onClick={() => setEditing(true)}>Edit</Button>
            <Button size="sm" variant="danger" onClick={() => act(async () => {
              if (!(await requestConfirm({ title: `Delete set ${set.key}?`, message: `Its ${set.scenario_count} scenarios are deleted. Its evaluation stays.`, confirmLabel: 'Delete set', danger: true }))) return;
              await change(path, 'DELETE', undefined, 'Could not delete the set');
            })}>Delete</Button>
          </div>
        </div>
      )}

      {expanded && (
        <ul style={{ listStyle: 'none', margin: '10px 0 0', padding: 0, display: 'grid', gap: 6 }}>
          {(set.scenarios || []).map((scenario) => (
            editingScenario === scenario.id ? (
              <li key={scenario.id}>
                <ScenarioForm
                  scenario={scenario}
                  onCancel={() => setEditingScenario(null)}
                  onSave={async (payload) => {
                    await change(`${path}/scenarios/${scenario.id}`, 'PATCH', payload, 'Could not save the scenario');
                    setEditingScenario(null);
                  }}
                />
              </li>
            ) : (
              <ScenarioRow
                key={scenario.id}
                scenario={scenario}
                selected={selection.scenarioIds.includes(scenario.id)}
                onToggle={() => onToggle('scenarioIds', scenario.id)}
                onEdit={() => setEditingScenario(scenario.id)}
                onDelete={() => act(async () => {
                  if (!(await requestConfirm({ title: `Delete scenario ${scenario.key}?`, confirmLabel: 'Delete scenario', danger: true }))) return;
                  await change(`${path}/scenarios/${scenario.id}`, 'DELETE', undefined, 'Could not delete the scenario');
                })}
              />
            )
          ))}
          <li>
            {editingScenario === 'new' ? (
              <ScenarioForm
                onCancel={() => setEditingScenario(null)}
                onSave={async (payload) => {
                  await change(`${path}/scenarios`, 'POST', payload, 'Could not add the scenario');
                  setEditingScenario(null);
                }}
              />
            ) : (
              <Button size="sm" variant="ghost" onClick={() => { setExpanded(true); setEditingScenario('new'); }} testId="scenarios-add-scenario">
                Add scenario
              </Button>
            )}
          </li>
        </ul>
      )}
    </div>
  );
}

function ScenarioRow({ scenario, selected, onToggle, onEdit, onDelete }) {
  const expectations = expectationText(scenario.expectations);
  return (
    <li style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '6px 8px', borderRadius: 6, background: 'var(--color-surface)' }}
      data-testid="scenarios-scenario">
      <input type="checkbox" aria-label={`Select scenario ${scenario.key}`} checked={selected} onChange={onToggle} style={{ marginTop: 3 }} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, color: 'var(--color-text-primary)', opacity: scenario.enabled ? 1 : 0.6 }}>
          <code style={{ fontSize: 11, color: 'var(--color-text-secondary)' }}>{scenario.key}</code> {scenario.prompt}
        </div>
        {(scenario.notes || expectations) && (
          <div style={{ fontSize: 12, color: 'var(--color-text-secondary)', marginTop: 2 }}>
            {scenario.notes}
            {scenario.notes && expectations ? ' · ' : ''}
            {expectations && <span style={{ fontFamily: MONO }}>{expectations}</span>}
          </div>
        )}
        <div style={{ display: 'flex', gap: 4, marginTop: 2, flexWrap: 'wrap' }}>
          {(scenario.tags || []).map((tag) => <Badge key={tag}>{tag}</Badge>)}
          {scenario.production_only && <Badge tone="warning">production only</Badge>}
          {!scenario.enabled && <Badge>disabled</Badge>}
        </div>
      </div>
      <Button size="sm" variant="ghost" onClick={onEdit}>Edit</Button>
      <Button size="sm" variant="ghost" onClick={onDelete}>Delete</Button>
    </li>
  );
}

// A save/cancel form whose save may throw: the message shows and the
// fields keep what was typed.
function SaveForm({ children, onSave, onCancel, problem = null, testId }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submit = async (event) => {
    event.preventDefault();
    if (problem) {
      setError(problem);
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await onSave();
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <form onSubmit={submit} style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: 10, border: '1px dashed var(--color-border)', borderRadius: 8 }}
      data-testid={testId}>
      {children}
      {error && <Notice tone="error">{error}</Notice>}
      <div style={{ display: 'flex', gap: 8 }}>
        <Button type="submit" size="sm" variant="primary" disabled={busy}>{busy ? 'Saving…' : 'Save'}</Button>
        <Button size="sm" variant="ghost" onClick={onCancel}>Cancel</Button>
      </div>
    </form>
  );
}

function ProductForm({ product = null, agents, projects, onSave, onCancel }) {
  const [name, setName] = useState(product?.name || '');
  const [key, setKey] = useState(product?.key || '');
  const [description, setDescription] = useState(product?.description || '');
  const [agentId, setAgentId] = useState(product?.agent ? String(product.agent.id) : '');
  const [projectId, setProjectId] = useState(product?.project ? String(product.project.id) : '');
  return (
    <SaveForm
      onCancel={onCancel}
      onSave={() => onSave({ name: name.trim(), key: key.trim(), description: description.trim(), agent_id: agentId, project_id: projectId })}
      testId="scenarios-product-form"
    >
      <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))' }}>
        <Field label="Name" value={name} onChange={setName} placeholder="Triage" />
        <Field label="Key" value={key} onChange={setKey} placeholder="made from the name when empty" mono />
        <Select label="Agent" value={agentId} onChange={setAgentId}>
          <option value="">None</option>
          {agents.map((agent) => <option key={agent.id} value={agent.id}>{agent.name}</option>)}
        </Select>
        <Select label="Project" value={projectId} onChange={setProjectId}>
          <option value="">None</option>
          {projects.map((project) => <option key={project.id} value={project.id}>{project.name}</option>)}
        </Select>
      </div>
      <Field label="Description" value={description} onChange={setDescription} placeholder="optional" />
    </SaveForm>
  );
}

function SetForm({ set = null, onSave, onCancel }) {
  const [name, setName] = useState(set?.name || '');
  const [key, setKey] = useState(set?.key || '');
  const [description, setDescription] = useState(set?.description || '');
  const [judge, setJudge] = useState(set?.judge?.kind || '');
  return (
    <SaveForm
      onCancel={onCancel}
      onSave={() => onSave({ name: name.trim(), key: key.trim(), description: description.trim(), ...(judge ? { judge: { kind: judge } } : {}) })}
      testId="scenarios-set-form"
    >
      <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))' }}>
        <Field label="Name" value={name} onChange={setName} placeholder="Smoke" />
        <Field label="Key" value={key} onChange={setKey} placeholder="made from the name when empty" mono />
        <Select label="Judge" value={judge} onChange={setJudge}>
          <option value="">The evaluation&apos;s default</option>
          <option value="rules">Rules (expectations only)</option>
          <option value="llm">LLM judge (grades against the notes)</option>
        </Select>
      </div>
      <Field label="Description" value={description} onChange={setDescription} placeholder="optional" />
    </SaveForm>
  );
}

function ScenarioForm({ scenario = null, onSave, onCancel }) {
  const [form, setForm] = useState(() => scenarioForm(scenario || {}));
  const set = (name) => (value) => setForm((current) => ({ ...current, [name]: value }));
  return (
    <SaveForm onCancel={onCancel} onSave={() => onSave(scenarioPayload(form))} problem={scenarioFormProblem(form)} testId="scenarios-scenario-form">
      <Field label="Prompt: what a user asks the agent" value={form.prompt} onChange={set('prompt')} multiline testId="scenario-prompt" />
      <Field label="Notes: the rubric, what a good answer does" value={form.notes} onChange={set('notes')} multiline rows={2} />
      <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))' }}>
        <Field label="Expected tools" value={form.tools} onChange={set('tools')} placeholder="lookup_order, refund_order" mono />
        <Field label="Answer contains" value={form.contains} onChange={set('contains')} placeholder="comma-separated" />
        <Field label="Answer never contains" value={form.notContains} onChange={set('notContains')} placeholder="comma-separated" />
        <Field label="Tags" value={form.tags} onChange={set('tags')} placeholder="billing, regression" />
        <Field label="Key" value={form.key} onChange={set('key')} placeholder="made from the prompt when empty" mono />
      </div>
      <div style={{ display: 'flex', gap: 16 }}>
        <Check label="Enabled" checked={form.enabled} onChange={set('enabled')} />
        <Check label="Production only" checked={form.productionOnly} onChange={set('productionOnly')} />
      </div>
    </SaveForm>
  );
}
