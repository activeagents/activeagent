import React, { useState } from 'react';
import { Badge, Button, MONO, Panel } from '../primitives';
import { secretWarnings } from '../../../utils/projects.mjs';

const formatWhen = (iso) => (iso ? new Date(iso).toLocaleString() : '—');
const SOURCE_LABELS = {
  entered: () => 'entered',
  organization_key: (secret) => `organization's ${secret.provider} key`,
  setup_assistant: () => 'set by the setup assistant, not secret',
};

// A project's Environment tab: each secret's name, source, who set it and
// when, from GET /api/projects/:id/secrets. A secret's value is never shown,
// and Replace takes a new one. A value the setup assistant set is not
// secret, so it is shown for a person to check. Replacing and deleting need
// :manage_project_secrets, and the API's refusal comes back through `error`.
//
// onReplace(name, value) and onDelete(name) return promises.
export default function ProjectEnvironment({ secrets, onReplace, onDelete, error }) {
  const [replacing, setReplacing] = useState(null);
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const warnings = replacing ? secretWarnings(replacing, value) : [];

  // A failure is reported by the caller through `error`; the form stays open.
  const run = async (action) => {
    setBusy(true);
    try {
      await action();
    } catch (_error) {
      return;
    } finally {
      setBusy(false);
    }
  };

  return (
    <Panel title="Environment" meta={`${secrets.length} ${secrets.length === 1 ? 'secret' : 'secrets'}`} testId="project-environment">
      {error && (
        <div style={{ padding: '8px 12px', fontSize: 13, background: 'var(--color-error-soft)', color: 'var(--color-error-text)' }}>{error}</div>
      )}
      {secrets.length === 0 && (
        <p style={{ margin: 0, padding: 12, fontSize: 13, color: 'var(--color-text-secondary)' }}>This project sets no environment variables.</p>
      )}
      <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
        {secrets.map((secret) => (
          <li key={secret.name} data-testid={`environment-${secret.name}`} style={{ padding: '10px 12px', borderTop: '1px solid var(--color-border-light)' }}>
            <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
              <span style={{ fontFamily: MONO, fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)' }}>{secret.name}</span>
              <Badge tone={secret.source === 'organization_key' ? 'info' : 'muted'}>
                {SOURCE_LABELS[secret.source]?.(secret) || 'entered'}
              </Badge>
              <span style={{ fontSize: 12, color: 'var(--color-text-muted)' }}>
                {secret.set_by?.name ? `set by ${secret.set_by.name}` : 'set'} · {formatWhen(secret.updated_at)}
              </span>
              <span style={{ marginLeft: 'auto', display: 'flex', gap: 6 }}>
                {secret.source !== 'organization_key' && (
                  <Button size="sm" onClick={() => { setReplacing(secret.name); setValue(''); }} disabled={busy}>Replace</Button>
                )}
                <Button size="sm" variant="danger" onClick={() => run(() => onDelete(secret.name))} disabled={busy}>Delete</Button>
              </span>
            </div>
            {secret.source === 'setup_assistant' && typeof secret.value === 'string' && (
              <div style={{ marginTop: 4, fontFamily: MONO, fontSize: 12, color: 'var(--color-text-secondary)', wordBreak: 'break-all' }}>
                {secret.name}={secret.value}
              </div>
            )}
            {replacing === secret.name && (
              <form
                style={{ display: 'flex', gap: 6, marginTop: 8, flexWrap: 'wrap' }}
                onSubmit={(event) => {
                  event.preventDefault();
                  if (!value) return;
                  run(async () => {
                    await onReplace(secret.name, value);
                    setReplacing(null);
                    setValue('');
                  });
                }}
              >
                <input
                  type="password"
                  autoComplete="off"
                  value={value}
                  onChange={(event) => setValue(event.target.value)}
                  placeholder="New value"
                  aria-label={`New value for ${secret.name}`}
                  style={{ flex: 1, minWidth: 200, padding: '6px 10px', borderRadius: 6, fontFamily: MONO, fontSize: 13,
                    border: '1px solid var(--color-border)', background: 'var(--color-card)', color: 'var(--color-text-primary)' }}
                />
                <Button size="sm" variant="primary" type="submit" disabled={!value || busy}>Save</Button>
                <Button size="sm" variant="ghost" onClick={() => setReplacing(null)}>Cancel</Button>
                {warnings.map((warning) => (
                  <div key={warning.code} style={{ width: '100%', fontSize: 12, color: 'var(--color-warning-text)' }}>{warning.message}</div>
                ))}
              </form>
            )}
          </li>
        ))}
      </ul>
    </Panel>
  );
}
