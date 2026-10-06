import React, { useState } from 'react';
import { Badge, Button, MicroLabel, MONO } from '../primitives';
import { secretNameProblem, secretWarnings, withSecretRow } from '../../../utils/projects.mjs';

const inputStyle = {
  width: '100%', padding: '6px 10px', borderRadius: 6, fontSize: 13, fontFamily: MONO,
  border: '1px solid var(--color-border)', background: 'var(--color-card)', color: 'var(--color-text-primary)',
};

// The project's one secrets form: a row per variable the repository expects
// (from GET /api/projects/discover_secrets) and any added by hand, each
// with a value field, the warnings that value raises, and for a provider key
// the option to use the organization's key instead. Rows are held by the
// caller (rows / onChange), as utils/projects.mjs secretRows builds them.
// Values are typed into password fields and never shown back.
export default function ProjectSecretsForm({ rows, onChange, repository }) {
  const [newName, setNewName] = useState('');
  const update = (index, changes) => onChange(rows.map((row, at) => (at === index ? { ...row, ...changes } : row)));
  const newNameProblem = newName ? secretNameProblem(newName) || (rows.some((row) => row.name === newName) ? `${newName} is already listed.` : null) : null;

  return (
    <div data-testid="project-secrets-form" style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      {rows.length === 0 && (
        <p style={{ margin: 0, fontSize: 13, color: 'var(--color-text-secondary)' }}>
          No environment variables were found in .env.example, .env.sample, .activeagents/sandbox.yml or ENV call sites.
        </p>
      )}
      {rows.map((row, index) => {
        const nameProblem = secretNameProblem(row.name);
        const warnings = row.useOrganizationKey ? [] : secretWarnings(row.name, row.value);
        return (
          <div key={row.name} data-testid={`secret-row-${row.name}`} style={{ borderTop: '1px solid var(--color-border-light)', paddingTop: 10 }}>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
              <span style={{ fontFamily: MONO, fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)' }}>{row.name}</span>
              {row.required && <Badge tone="warning">required</Badge>}
              {row.set && <Badge tone="success">set</Badge>}
              {row.sources?.length > 0 && (
                <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{row.sources.join(' · ')}</span>
              )}
            </div>
            {row.description && <div style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>{row.description}</div>}
            {nameProblem ? (
              <div style={{ fontSize: 12, color: 'var(--color-error-text)' }}>{nameProblem}</div>
            ) : (
              <>
                {!row.useOrganizationKey && (
                  <input
                    type="password"
                    autoComplete="off"
                    value={row.value}
                    onChange={(event) => update(index, { value: event.target.value })}
                    placeholder={row.set ? 'Leave empty to keep the current value' : 'Value'}
                    aria-label={`${row.name} value`}
                    style={{ ...inputStyle, marginTop: 6 }}
                  />
                )}
                {row.organizationKey && (
                  <label style={{ display: 'flex', gap: 6, alignItems: 'center', marginTop: 6, fontSize: 13, color: 'var(--color-text-cell)' }}>
                    <input
                      type="checkbox"
                      checked={row.useOrganizationKey}
                      onChange={(event) => update(index, { useOrganizationKey: event.target.checked, consent: false, value: '' })}
                    />
                    Use the organization's {row.organizationKey} key
                  </label>
                )}
                {row.useOrganizationKey && (
                  <label data-testid={`secret-consent-${row.name}`} style={{ display: 'flex', gap: 6, alignItems: 'flex-start', marginTop: 4, fontSize: 12, color: 'var(--color-warning-text)' }}>
                    <input type="checkbox" checked={row.consent} onChange={(event) => update(index, { consent: event.target.checked })} />
                    I understand {repository || 'the repository'}'s code can read the organization's {row.organizationKey} key. It is read when the sandbox boots and never copied into the project.
                  </label>
                )}
                {warnings.map((warning) => (
                  <div key={warning.code} data-testid={`secret-warning-${warning.code}`} style={{ marginTop: 4, fontSize: 12, color: 'var(--color-warning-text)' }}>
                    {warning.message}
                  </div>
                ))}
              </>
            )}
          </div>
        );
      })}

      <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', borderTop: '1px solid var(--color-border-light)', paddingTop: 10 }}>
        <div style={{ flex: 1 }}>
          <MicroLabel as="label" htmlFor="project-secret-new-name">Another variable</MicroLabel>
          <input
            id="project-secret-new-name"
            type="text"
            value={newName}
            onChange={(event) => setNewName(event.target.value.trim())}
            placeholder="NAME"
            style={{ ...inputStyle, marginTop: 4 }}
          />
          {newNameProblem && <div style={{ fontSize: 12, color: 'var(--color-error-text)' }}>{newNameProblem}</div>}
        </div>
        <Button
          size="sm"
          style={{ marginTop: 20 }}
          disabled={!newName || Boolean(newNameProblem)}
          onClick={() => {
            onChange(withSecretRow(rows, newName));
            setNewName('');
          }}
        >
          Add
        </Button>
      </div>
    </div>
  );
}
