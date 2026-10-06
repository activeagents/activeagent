import React from 'react';
import { Glyph, MicroLabel, MONO, Panel } from '../primitives';

// The New Project checklist (GET /api/projects/capabilities): one row per
// item, with the configuration line or step that fixes a failing one. A
// failing blocking item is marked as blocking creation.
export default function CapabilitiesChecklist({ capabilities }) {
  const items = capabilities?.items || [];

  return (
    <Panel title="Before you start" meta={capabilities?.ready ? 'ready' : 'action needed'} testId="project-capabilities">
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
    </Panel>
  );
}
