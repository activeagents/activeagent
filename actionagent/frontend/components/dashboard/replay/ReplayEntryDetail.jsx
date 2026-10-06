import React from 'react';
import { Badge, MicroLabel, MONO } from '../primitives';
import { LANE_ROWS } from './ReplayScrubber';
import { entryFailed } from '../../../utils/replayEntries.mjs';

// One timeline entry in full: when it ran, its trace, and what its lane
// records of it.

const LABELS = Object.fromEntries(LANE_ROWS.map((row) => [row.lane, row.label]));

const preStyle = {
  margin: 0, padding: '8px 10px', borderRadius: 8, background: 'var(--color-background)', border: '1px solid var(--color-border-light)',
  fontFamily: MONO, fontSize: 12, lineHeight: '18px', color: 'var(--color-text-cell)', whiteSpace: 'pre-wrap', wordBreak: 'break-word',
  maxHeight: 220, overflow: 'auto',
};

function asText(value) {
  if (value == null || value === '') return null;
  if (typeof value === 'string') return value;
  return JSON.stringify(value, null, 2);
}

function Field({ label, value }) {
  const text = asText(value);
  if (text == null) return null;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
      <MicroLabel size={10}>{label}</MicroLabel>
      <pre style={preStyle}>{text}</pre>
    </div>
  );
}

// The fields each lane shows, as [label, value].
function fieldsFor(entry) {
  switch (entry.lane) {
    case 'message':
      return [['content', entry.content], ['tool calls', entry.tool_calls?.length ? entry.tool_calls : null]];
    case 'llm':
      return [['model', [entry.provider, entry.model].filter(Boolean).join(' / ')], ['finish reason', entry.finish_reason], ['tokens', entry.tokens]];
    case 'tool':
      return [['arguments', entry.arguments], ['result', entry.result ?? entry.detail]];
    case 'browser':
      return [['event', entry.data]];
    default:
      return [];
  }
}

export default function ReplayEntryDetail({ entry }) {
  if (!entry) {
    return <div style={{ padding: 16, fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>choose an entry to see it in full</div>;
  }

  return (
    <div data-testid="replay-entry-detail" style={{ padding: 14, display: 'flex', flexDirection: 'column', gap: 10 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <Badge tone={entryFailed(entry) ? 'error' : 'muted'}>{LABELS[entry.lane]}</Badge>
        {entry.role && <Badge tone="info">{entry.role}</Badge>}
        {(entry.name || entry.tool_name) && entry.lane !== 'llm' && (
          <span style={{ fontFamily: MONO, fontSize: 12, fontWeight: 600, color: 'var(--color-text-primary)' }}>{entry.name || entry.tool_name}</span>
        )}
        <span style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }} title={entry.start}>
          {new Date(entry.startMs).toLocaleTimeString()}{entry.duration_ms > 0 ? ` · ${Math.round(entry.duration_ms)}ms` : ''}
        </span>
      </div>
      {entry.trace_id && (
        <div style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>trace {entry.trace_id}</div>
      )}
      {fieldsFor(entry).map(([label, value]) => <Field key={label} label={label} value={value} />)}
    </div>
  );
}
