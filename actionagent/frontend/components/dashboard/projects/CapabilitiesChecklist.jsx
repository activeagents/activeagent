import React, { useState } from 'react';
import { Glyph, MicroLabel, MONO, Panel } from '../primitives';

// One line saying how the checklist stands: "ready", or how many items need
// action and how many of those block creating a project.
export function capabilitiesSummary(items) {
  const failing = items.filter((item) => !item.ok);
  if (failing.length === 0) return 'ready';
  const blocking = failing.filter((item) => item.blocking).length;
  const need = `${failing.length} ${failing.length === 1 ? 'item needs' : 'items need'} action`;
  return blocking ? `${need} · ${blocking} ${blocking === 1 ? 'blocks' : 'block'} creating a project` : need;
}

// The New Project checklist (GET /api/projects/capabilities): one row per
// item, with the configuration line or step that fixes a failing one. A
// failing blocking item is marked as blocking creation. It sits below the
// repository picker as a one-line summary, open from the start only when an
// item blocks creating a project.
export default function CapabilitiesChecklist({ capabilities }) {
  const items = capabilities?.items || [];
  const blocked = items.some((item) => !item.ok && item.blocking);
  const [open, setOpen] = useState(blocked);
  const summary = capabilitiesSummary(items);

  return (
    <Panel title="Before you start" meta={capabilities?.ready ? 'ready' : 'action needed'} testId="project-capabilities">
      <button
        type="button"
        data-testid="capabilities-toggle"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
        style={{ display: 'flex', width: '100%', alignItems: 'center', gap: 8, padding: '8px 12px', border: 0, background: 'transparent',
          cursor: 'pointer', fontSize: 13, color: blocked ? 'var(--color-error-text)' : 'var(--color-text-secondary)', textAlign: 'left' }}
      >
        <span aria-hidden="true">{open ? '▾' : '▸'}</span>
        <span data-testid="capabilities-summary">{summary}</span>
        <span style={{ marginLeft: 'auto', fontSize: 12, color: 'var(--color-text-muted)' }}>{open ? 'Hide' : 'Show'} checklist</span>
      </button>
      {open && (
        <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
          {items.map((item) => (
            <li
              key={item.key}
              data-testid={`capability-${item.key}`}
              style={{ display: 'flex', gap: 10, padding: '10px 12px', borderTop: '1px solid var(--color-border-light)' }}
            >
              <Glyph kind={item.ok ? 'pass' : item.blocking ? 'fault' : 'info'} />
              <div style={{ minWidth: 0, flex: 1 }}>
                <div style={{ display: 'flex', gap: 8, alignItems: 'baseline', flexWrap: 'wrap' }}>
                  <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)' }}>{item.label}</span>
                  {!item.ok && item.blocking && <MicroLabel color="var(--color-error-text)">blocks creating a project</MicroLabel>}
                </div>
                {item.detail && <div style={{ fontSize: 13, color: 'var(--color-text-secondary)', overflowWrap: 'anywhere' }}>{item.detail}</div>}
                {!item.ok && item.fix && (
                  <code
                    data-testid={`capability-fix-${item.key}`}
                    style={{ display: 'block', marginTop: 6, padding: '6px 8px', borderRadius: 6, fontFamily: MONO, fontSize: 12,
                      background: 'var(--color-muted)', color: 'var(--color-text-cell)', overflowWrap: 'anywhere' }}
                  >
                    {item.fix}
                  </code>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
    </Panel>
  );
}
