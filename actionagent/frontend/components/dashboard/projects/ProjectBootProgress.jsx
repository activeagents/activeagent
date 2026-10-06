import React from 'react';
import { Badge, MONO, Panel } from '../primitives';
import { STEP_TONES, bootStepGroup, formatElapsed } from '../../../utils/projects.mjs';
import { waitingLabel } from '../../../utils/projectSetup.mjs';

// A project's boot, step by step (GET /api/projects/:id/boot): each step's
// status, elapsed time and detail, then the scrubbed tail of the step that
// failed or is running. `boot` is null when the backend reports no steps.
// `waiting` counts the requests for input the project's agents wait on.
export default function ProjectBootProgress({ boot, logTail, error, sandboxState, waiting }) {
  const steps = boot?.steps || [];

  return (
    <Panel title="Boot" meta={waitingLabel(waiting) || sandboxState || 'none'} testId="project-boot-progress">
      {steps.length === 0 && (
        <p style={{ margin: 0, padding: 12, fontSize: 13, color: 'var(--color-text-secondary)' }}>
          {sandboxState === 'booting' ? 'Waiting for the sandbox to report its steps…' : 'No boot to show yet.'}
        </p>
      )}
      {steps.length > 0 && (
        <ol style={{ listStyle: 'none', margin: 0, padding: 0 }}>
          {steps.map((step) => (
            <li
              key={step.name}
              data-testid={`boot-step-${step.name}`}
              style={{ display: 'grid', gridTemplateColumns: '92px 170px 1fr 80px', gap: 10, alignItems: 'baseline',
                padding: '8px 12px', borderTop: '1px solid var(--color-border-light)' }}
            >
              <Badge tone={STEP_TONES[step.status] || 'muted'}>{step.status}</Badge>
              <span style={{ fontSize: 13, color: 'var(--color-text-primary)' }}>
                {bootStepGroup(step.name)} <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{step.name}</span>
              </span>
              <span style={{ fontSize: 12, color: 'var(--color-text-secondary)', overflowWrap: 'anywhere' }}>{step.detail || ''}</span>
              <span style={{ fontFamily: MONO, fontSize: 12, color: 'var(--color-text-muted)', textAlign: 'right' }}>
                {step.status === 'pending' ? '' : formatElapsed(step.duration_ms)}
              </span>
            </li>
          ))}
        </ol>
      )}
      {error && (
        <div data-testid="boot-error" style={{ padding: '8px 12px', fontSize: 13, background: 'var(--color-error-soft)', color: 'var(--color-error-text)', whiteSpace: 'pre-wrap' }}>
          {error}
        </div>
      )}
      {logTail?.text && (
        <div style={{ borderTop: '1px solid var(--color-border-light)' }}>
          <div style={{ padding: '6px 12px', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
            {logTail.truncated ? 'last lines of ' : ''}{logTail.step}.log
          </div>
          <pre
            data-testid="boot-log-tail"
            style={{ margin: 0, padding: '8px 12px', maxHeight: 280, overflow: 'auto', fontFamily: MONO, fontSize: 12,
              background: 'var(--color-muted)', color: 'var(--color-text-cell)', whiteSpace: 'pre-wrap' }}
          >
            {logTail.text}
          </pre>
        </div>
      )}
    </Panel>
  );
}
