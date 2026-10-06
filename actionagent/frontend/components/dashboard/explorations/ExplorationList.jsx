import React from 'react';
import { Badge, Card, MONO } from '../primitives';
import { timeAgo } from '../../../utils/format';
import { STATUS_TONES } from '../../../utils/explorations.mjs';

// Explorations, newest first (GET /api/explorations), each with its status
// and what it found. `selectedId` marks the one open beside the list.
export default function ExplorationList({ explorations, onOpen, selectedId = null }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }} data-testid="exploration-list">
      {explorations.map((exploration) => {
        const counts = exploration.counts || {};
        const current = String(exploration.id) === String(selectedId);
        return (
          <Card key={exploration.id} padding={12} testId={`exploration-${exploration.id}`}
            style={current ? { borderColor: 'var(--color-accent-ui)' } : undefined}>
            <button
              type="button"
              onClick={() => onOpen(exploration)}
              style={{ all: 'unset', cursor: 'pointer', display: 'flex', gap: 8, alignItems: 'center', width: '100%', flexWrap: 'wrap' }}
            >
              <span style={{ fontFamily: MONO, fontSize: 12, color: 'var(--color-text-primary)' }}>#{exploration.id}</span>
              <Badge tone={STATUS_TONES[exploration.status] || 'muted'}>{exploration.status}</Badge>
              <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>{exploration.source}</span>
              <span style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
                {counts.total || 0} found · {counts.open || 0} to review · {counts.accepted || 0} accepted · {timeAgo(exploration.created_at)}
              </span>
            </button>
          </Card>
        );
      })}
    </div>
  );
}
