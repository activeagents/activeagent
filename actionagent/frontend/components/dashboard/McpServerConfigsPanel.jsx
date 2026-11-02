import React, { useCallback, useEffect, useState } from 'react';
import { Badge, Button, Card, MicroLabel, MONO } from './primitives';
import { requestConfirm } from '../../utils/confirm.mjs';
import {
  addHeader,
  draftFrom,
  emptyDraft,
  errorText,
  hasErrors,
  removeHeader,
  requestBody,
  testStatus,
  updateHeader,
  validateDraft,
} from '../../utils/mcpServerConfigs.mjs';

const inputStyle = {
  width: '100%', boxSizing: 'border-box', padding: '8px 10px', borderRadius: 8, fontSize: 13,
  border: '1px solid var(--color-border-strong)', background: 'var(--color-card)', color: 'var(--color-text-primary)',
};

/**
 * McpServerConfigsPanel — the remote MCP servers this owner added by URL,
 * each enabled on agents as "custom:<id>" from the agent editor's Tools tab.
 *
 * Lists the servers with their last connection test, and adds, edits, tests
 * and deletes them. Header values are write-only: a stored header shows its
 * masked hint, and leaving its value blank keeps it. `onChanged` lets the
 * page refresh the services list, which shows these servers too.
 */
export default function McpServerConfigsPanel({ onChanged }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState(null);
  const [draft, setDraft] = useState(null);
  const [formError, setFormError] = useState(null);
  const [saving, setSaving] = useState(false);
  const [testing, setTesting] = useState(null);
  const [notice, setNotice] = useState(null);

  const load = useCallback(async () => {
    try {
      const response = await fetch('/api/mcp_server_configs');
      if (!response.ok) throw new Error(`Request failed (${response.status})`);
      setData(await response.json());
      setLoadError(null);
    } catch (error) {
      setLoadError(error.message);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const changed = () => {
    load();
    if (onChanged) onChanged();
  };

  const save = async () => {
    const errors = validateDraft(draft);
    if (hasErrors(errors)) {
      setFormError(Object.values(errors).join(' '));
      return;
    }

    setSaving(true);
    setFormError(null);
    try {
      const path = draft.id ? `/api/mcp_server_configs/${draft.id}` : '/api/mcp_server_configs';
      const response = await fetch(path, {
        method: draft.id ? 'PATCH' : 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(requestBody(draft)),
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(errorText(body, 'Could not save the server.'));

      setDraft(null);
      setNotice({ kind: 'ok', text: `${body.mcp_server_config.name} saved. Test it to list the tools it serves.` });
      changed();
    } catch (error) {
      setFormError(error.message);
    } finally {
      setSaving(false);
    }
  };

  const test = async (config) => {
    setTesting(config.id);
    setNotice(null);
    try {
      const response = await fetch(`/api/mcp_server_configs/${config.id}/test`, { method: 'POST' });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(errorText(body, 'Could not test the server.'));

      setNotice(body.ok
        ? { kind: 'ok', text: `${config.name} answered with ${body.tools.length} tool${body.tools.length === 1 ? '' : 's'}.` }
        : { kind: 'error', text: `${config.name}: ${body.error}` });
      changed();
    } catch (error) {
      setNotice({ kind: 'error', text: error.message });
    } finally {
      setTesting(null);
    }
  };

  const toggle = async (config) => {
    try {
      const response = await fetch(`/api/mcp_server_configs/${config.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ mcp_server_config: { enabled: !config.enabled } }),
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(errorText(body, 'Could not change the server.'));
      changed();
    } catch (error) {
      setNotice({ kind: 'error', text: error.message });
    }
  };

  const remove = async (config) => {
    const confirmed = await requestConfirm({
      title: `Delete ${config.name}?`,
      message: 'Agents that enable it keep its entry, but can no longer call its tools until it is switched off or replaced.',
      confirmLabel: 'Delete server',
      danger: true,
    });
    if (!confirmed) return;

    try {
      const response = await fetch(`/api/mcp_server_configs/${config.id}`, { method: 'DELETE' });
      if (!response.ok) {
        const body = await response.json().catch(() => ({}));
        throw new Error(errorText(body, 'Could not delete the server.'));
      }
      changed();
    } catch (error) {
      setNotice({ kind: 'error', text: error.message });
    }
  };

  const configs = data?.mcp_server_configs || [];
  const canManage = data ? data.can_manage !== false : false;

  return (
    <Card testId="mcp-server-configs" style={{ marginBottom: 16 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 12, flexWrap: 'wrap' }}>
        <div>
          <h3 style={{ fontSize: 16, fontWeight: 600, color: 'var(--color-text-primary)', margin: 0 }}>Your MCP servers</h3>
          <p style={{ fontSize: 13, color: 'var(--color-text-secondary)', margin: '4px 0 0 0' }}>
            Remote servers you connect by URL. Enable one on an agent from its Tools tab; runs and evaluations then call its tools.
          </p>
        </div>
        {canManage && !draft && (
          <Button variant="primary" size="sm" testId="mcp-server-config-add" onClick={() => { setDraft(emptyDraft()); setFormError(null); }}>
            Add server
          </Button>
        )}
      </div>

      {loadError && <p role="alert" style={{ color: 'var(--color-error)', fontSize: 13 }}>Failed to load your servers: {loadError}</p>}
      {notice && (
        <p role="status" style={{ fontSize: 13, margin: '12px 0 0 0', color: notice.kind === 'error' ? 'var(--color-error)' : 'var(--color-success-text)' }}>
          {notice.text}
        </p>
      )}

      {draft && (
        <ServerForm
          draft={draft}
          setDraft={setDraft}
          error={formError}
          saving={saving}
          allowPrivate={data?.allow_private_hosts}
          onSave={save}
          onCancel={() => { setDraft(null); setFormError(null); }}
        />
      )}

      <div style={{ display: 'grid', gap: 8, marginTop: 12 }}>
        {data && configs.length === 0 && !draft && (
          <p style={{ fontSize: 13, color: 'var(--color-text-muted)', margin: 0 }}>No servers added yet.</p>
        )}
        {configs.map((config) => {
          const status = testStatus(config);
          return (
            <div
              key={config.id}
              data-testid={`mcp-server-config-${config.id}`}
              style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap', padding: '10px 12px', borderRadius: 8, border: '1px solid var(--color-border)' }}
            >
              <div style={{ flex: 1, minWidth: 220 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                  <span style={{ fontSize: 14, fontWeight: 600, color: 'var(--color-text-primary)' }}>{config.name}</span>
                  <Badge tone={status.tone} title={status.title}>{status.label}</Badge>
                  {!config.enabled && <Badge tone="warning">switched off</Badge>}
                </div>
                <div style={{ fontFamily: MONO, fontSize: 12, color: 'var(--color-text-secondary)', marginTop: 2, wordBreak: 'break-all' }}>
                  {config.url}
                </div>
                {config.headers.length > 0 && (
                  <div style={{ fontSize: 12, color: 'var(--color-text-muted)', marginTop: 2 }}>
                    Headers: {config.headers.map((header) => `${header.name}: ${header.hint}`).join(', ')}
                  </div>
                )}
                {config.last_test_status === 'failed' && config.last_test_error && (
                  <div style={{ fontSize: 12, color: 'var(--color-error)', marginTop: 2 }}>{config.last_test_error}</div>
                )}
              </div>
              {canManage && (
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  <Button size="sm" onClick={() => test(config)} disabled={testing === config.id} testId={`mcp-server-config-test-${config.id}`}>
                    {testing === config.id ? 'Testing…' : 'Test'}
                  </Button>
                  <Button size="sm" variant="ghost" onClick={() => toggle(config)}>
                    {config.enabled ? 'Switch off' : 'Switch on'}
                  </Button>
                  <Button size="sm" variant="ghost" onClick={() => { setDraft(draftFrom(config)); setFormError(null); }}>Edit</Button>
                  <Button size="sm" variant="danger" onClick={() => remove(config)}>Delete</Button>
                </div>
              )}
            </div>
          );
        })}
      </div>
    </Card>
  );
}

// The add/edit form. A stored header's value field is empty, with its masked
// hint as the placeholder; typing replaces the value, leaving it keeps it.
function ServerForm({ draft, setDraft, error, saving, allowPrivate, onSave, onCancel }) {
  const set = (field) => (event) => setDraft({ ...draft, [field]: field === 'enabled' ? event.target.checked : event.target.value });

  return (
    <div data-testid="mcp-server-config-form" style={{ marginTop: 12, padding: 12, borderRadius: 8, border: '1px solid var(--color-border-strong)', display: 'grid', gap: 10 }}>
      <label style={{ display: 'grid', gap: 4 }}>
        <MicroLabel>Name</MicroLabel>
        <input style={inputStyle} value={draft.name} onChange={set('name')} placeholder="Orders API" aria-label="Server name" />
      </label>
      <label style={{ display: 'grid', gap: 4 }}>
        <MicroLabel>URL</MicroLabel>
        <input style={{ ...inputStyle, fontFamily: MONO }} value={draft.url} onChange={set('url')} placeholder="https://app.example.com/mcp" aria-label="Server URL" />
        <span style={{ fontSize: 12, color: 'var(--color-text-muted)' }}>
          Streamable HTTP endpoint.{allowPrivate ? '' : ' Private, loopback and link-local addresses are not reachable from here.'}
        </span>
      </label>
      <label style={{ display: 'grid', gap: 4 }}>
        <MicroLabel>Description</MicroLabel>
        <input style={inputStyle} value={draft.description} onChange={set('description')} placeholder="Optional" aria-label="Server description" />
      </label>

      <div style={{ display: 'grid', gap: 6 }}>
        <MicroLabel>Headers</MicroLabel>
        {draft.headers.map((header, index) => (
          <div key={index} style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
            <input
              style={{ ...inputStyle, flex: '0 0 35%', fontFamily: MONO }}
              value={header.name}
              onChange={(event) => setDraft(updateHeader(draft, index, 'name', event.target.value))}
              placeholder="Authorization"
              aria-label={`Header ${index + 1} name`}
            />
            <input
              type="password"
              data-aa-secret=""
              autoComplete="off"
              style={{ ...inputStyle, flex: 1, fontFamily: MONO }}
              value={header.value}
              onChange={(event) => setDraft(updateHeader(draft, index, 'value', event.target.value))}
              placeholder={header.stored ? `stored ${header.hint} — leave blank to keep` : 'Bearer …'}
              aria-label={`Header ${index + 1} value`}
            />
            <Button size="sm" variant="ghost" onClick={() => setDraft(removeHeader(draft, index))} title="Remove this header">Remove</Button>
          </div>
        ))}
        <div>
          <Button size="sm" variant="ghost" onClick={() => setDraft(addHeader(draft))}>+ Add header</Button>
        </div>
      </div>

      <label style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 13, color: 'var(--color-text-cell)' }}>
        <input type="checkbox" checked={draft.enabled} onChange={set('enabled')} />
        Agents that enable it may call it
      </label>

      {error && <p role="alert" style={{ color: 'var(--color-error)', fontSize: 13, margin: 0 }}>{error}</p>}

      <div style={{ display: 'flex', gap: 8 }}>
        <Button variant="primary" size="sm" onClick={onSave} disabled={saving} testId="mcp-server-config-save">
          {saving ? 'Saving…' : draft.id ? 'Save changes' : 'Add server'}
        </Button>
        <Button size="sm" variant="ghost" onClick={onCancel}>Cancel</Button>
      </div>
    </div>
  );
}
