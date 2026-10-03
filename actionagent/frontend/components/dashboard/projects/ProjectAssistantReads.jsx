import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Badge, Button, MONO, Panel } from '../primitives';
import { apiErrorMessage } from '../../../utils/codeSessions.mjs';
import { schemaToolsChanged, schemaToolsPayload, selectionFromChoices, toggleColumn } from '../../../utils/projectSetup.mjs';

async function readJson(res) {
  return res.json().catch(() => ({}));
}

// "Choose what the assistant may read", for a project evaluated with the App
// assistant: the app's models as the last boot listed them, and for each
// column whether the assistant may filter on it and read it back. Saving
// stores the choices, which every later boot writes as
// app/agent_tools/<model>_tools.rb; Save and restart boots the project again
// now, so the assistant's tools follow at once.
export default function ProjectAssistantReads({ project, onSaved, onConfirmationRequired }) {
  const [models, setModels] = useState(null);
  const [selection, setSelection] = useState({});
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const choices = project.schema_tools || [];

  const load = useCallback(async () => {
    const res = await fetch(`/api/projects/${project.id}/app_models`);
    const data = await readJson(res);
    if (res.status === 409) { setModels(null); return; }
    if (!res.ok) throw new Error(apiErrorMessage(data, `Could not list the app's models (HTTP ${res.status}).`));
    setModels(data.models || []);
    setSelection(selectionFromChoices(data.schema_tools || []));
  }, [project.id]);

  useEffect(() => {
    if (project.app_models_listed) load().catch((e) => setError(e.message));
  }, [load, project.app_models_listed]);

  const save = async (apply, confirm = false) => {
    setBusy(true);
    setError(null);
    try {
      const res = await fetch(`/api/projects/${project.id}/schema_tools`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ schema_tools: schemaToolsPayload(selection, models || []), apply, ...(confirm ? { confirm: true } : {}) }),
      });
      const data = await readJson(res);
      if (res.status === 409 && data.code === 'confirmation_required') {
        onConfirmationRequired?.(data.confirmation, () => save(apply, true));
        return;
      }
      if (!res.ok) throw new Error(apiErrorMessage(data, `Could not save what the assistant may read (HTTP ${res.status}).`));
      onSaved?.(data.project);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <AssistantReadsView
      listed={project.app_models_listed}
      models={models}
      selection={selection}
      changed={models ? schemaToolsChanged(selection, choices, models) : false}
      busy={busy}
      error={error}
      onToggle={(model, option, column) => setSelection((current) => toggleColumn(current, model, option, column))}
      onSave={() => save(false)}
      onSaveAndRestart={() => save(true)}
    />
  );
}

// The chooser as it renders from its props.
export function AssistantReadsView({ listed, models, selection, changed, busy, error, onToggle, onSave, onSaveAndRestart }) {
  const chosen = useMemo(() => Object.keys(selection || {}), [selection]);

  return (
    <Panel title="Choose what the assistant may read" meta={`${chosen.length} ${chosen.length === 1 ? 'model' : 'models'}`} testId="project-assistant-reads">
      <p style={{ margin: 0, padding: '10px 12px', fontSize: 13, color: 'var(--color-text-secondary)' }}>
        Each model you choose gets find, count and get tools that filter on and return only the columns ticked here. Columns that look
        like secrets are never listed. The tools are written into the sandbox&apos;s checkout on every boot, and go into the install pull request.
      </p>
      {!listed && (
        <p style={{ margin: 0, padding: '0 12px 12px', fontSize: 13, color: 'var(--color-text-secondary)' }}>
          Boot the project first: a boot lists the app&apos;s models.
        </p>
      )}
      {error && <div style={{ padding: '8px 12px', fontSize: 13, color: 'var(--color-error-text)' }}>{error}</div>}
      {listed && models && models.length === 0 && (
        <p style={{ margin: 0, padding: '0 12px 12px', fontSize: 13, color: 'var(--color-text-secondary)' }}>The app has no models with a table.</p>
      )}
      {(models || []).map((model) => {
        const picked = selection?.[model.name];
        return (
          <details key={model.name} open={Boolean(picked)} data-testid={`assistant-model-${model.name}`}
            style={{ borderTop: '1px solid var(--color-border-light)', padding: '8px 12px' }}>
            <summary style={{ cursor: 'pointer', display: 'flex', gap: 8, alignItems: 'center' }}>
              <span style={{ fontFamily: MONO, fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)' }}>{model.name}</span>
              <span style={{ fontSize: 12, color: 'var(--color-text-muted)' }}>{model.table}</span>
              {picked && <Badge tone="accent">{`${picked.filterable.size} filter · ${picked.returns.size} read`}</Badge>}
            </summary>
            <table style={{ marginTop: 6, borderCollapse: 'collapse', fontSize: 12 }}>
              <thead>
                <tr style={{ color: 'var(--color-text-muted)', textAlign: 'left' }}>
                  <th style={{ padding: '2px 12px 2px 0', fontWeight: 500 }}>Column</th>
                  <th style={{ padding: '2px 12px', fontWeight: 500 }}>Filter on</th>
                  <th style={{ padding: '2px 12px', fontWeight: 500 }}>Read back</th>
                </tr>
              </thead>
              <tbody>
                {model.columns.map((column) => (
                  <tr key={column.name}>
                    <td style={{ padding: '2px 12px 2px 0', fontFamily: MONO, color: 'var(--color-text-primary)' }}>
                      {column.name} <span style={{ color: 'var(--color-text-muted)' }}>{column.type}</span>
                    </td>
                    {['filterable', 'returns'].map((option) => (
                      <td key={option} style={{ padding: '2px 12px', textAlign: 'center' }}>
                        <input
                          type="checkbox"
                          aria-label={`${option === 'filterable' ? 'Filter on' : 'Read back'} ${model.name}.${column.name}`}
                          checked={Boolean(picked?.[option]?.has(column.name))}
                          disabled={busy}
                          onChange={() => onToggle(model.name, option, column.name)}
                        />
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </details>
        );
      })}
      {listed && models && models.length > 0 && (
        <div style={{ display: 'flex', gap: 8, padding: '10px 12px', borderTop: '1px solid var(--color-border-light)' }}>
          <Button size="sm" onClick={onSave} disabled={busy || !changed}>Save</Button>
          <Button size="sm" variant="primary" onClick={onSaveAndRestart} disabled={busy} testId="assistant-reads-restart">
            {busy ? 'Saving…' : 'Save and restart the sandbox'}
          </Button>
        </div>
      )}
    </Panel>
  );
}
