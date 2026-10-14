import React from 'react';
import { MONO } from '../primitives';

// The Scenarios page's form controls and notices.

const inputStyle = (mono) => ({
  padding: '6px 8px', borderRadius: 6, border: '1px solid var(--color-border)', background: 'var(--color-surface)',
  color: 'var(--color-text-primary)', fontSize: 13, fontFamily: mono ? MONO : undefined,
});

export function Field({ label, value, onChange, placeholder, mono = false, multiline = false, rows = 3, testId }) {
  return (
    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12, color: 'var(--color-text-secondary)' }}>
      {label}
      {multiline ? (
        <textarea value={value} onChange={(event) => onChange(event.target.value)} placeholder={placeholder} rows={rows}
          style={{ ...inputStyle(mono), resize: 'vertical' }} data-testid={testId} />
      ) : (
        <input value={value} onChange={(event) => onChange(event.target.value)} placeholder={placeholder} style={inputStyle(mono)} data-testid={testId} />
      )}
    </label>
  );
}

export function Select({ label, value, onChange, children, testId }) {
  return (
    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12, color: 'var(--color-text-secondary)' }}>
      {label}
      <select value={value} onChange={(event) => onChange(event.target.value)} style={inputStyle(false)} data-testid={testId}>
        {children}
      </select>
    </label>
  );
}

export function Check({ label, checked, onChange }) {
  return (
    <label style={{ display: 'inline-flex', gap: 6, alignItems: 'center', fontSize: 12, color: 'var(--color-text-secondary)' }}>
      <input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} />
      {label}
    </label>
  );
}

export function Notice({ tone = 'info', children }) {
  const error = tone === 'error';
  return (
    <div
      role={error ? 'alert' : 'status'}
      style={{
        fontSize: 13, padding: '8px 10px', borderRadius: 8,
        background: error ? 'var(--color-error-soft)' : 'transparent',
        color: error ? 'var(--color-error-text)' : 'var(--color-text-secondary)',
        border: error ? 'none' : '1px solid var(--color-border)',
      }}
    >
      {children}
    </div>
  );
}
