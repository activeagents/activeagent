import React, { useId } from 'react';
import { MONO } from '../primitives';

// The Scenarios page's form controls and notices.

const inputStyle = (mono) => ({
  padding: '6px 8px', borderRadius: 6, border: '1px solid var(--color-border)', background: 'var(--color-surface)',
  color: 'var(--color-text-primary)', fontSize: 13, fontFamily: mono ? MONO : undefined,
});

const fieldStyle = { display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12, color: 'var(--color-text-secondary)' };

// The accessible name of a control: its label, when the label is text.
const accessibleName = (label) => (typeof label === 'string' ? label : undefined);

// A labelled text box. The label is tied to the control by id as well as by
// wrapping it, so every screen reader names the box (a textarea inside a
// flex label was read as an unnamed "textbox").
export function Field({ label, value, onChange, placeholder, mono = false, multiline = false, rows = 3, testId }) {
  const id = useId();
  const common = { id, value, onChange: (event) => onChange(event.target.value), placeholder, 'aria-label': accessibleName(label), 'data-testid': testId };
  return (
    <div style={fieldStyle}>
      <label htmlFor={id}>{label}</label>
      {multiline
        ? <textarea {...common} rows={rows} style={{ ...inputStyle(mono), resize: 'vertical' }} />
        : <input {...common} style={inputStyle(mono)} />}
    </div>
  );
}

export function Select({ label, value, onChange, children, testId }) {
  const id = useId();
  return (
    <div style={fieldStyle}>
      <label htmlFor={id}>{label}</label>
      <select id={id} value={value} onChange={(event) => onChange(event.target.value)} aria-label={accessibleName(label)}
        style={inputStyle(false)} data-testid={testId}>
        {children}
      </select>
    </div>
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
