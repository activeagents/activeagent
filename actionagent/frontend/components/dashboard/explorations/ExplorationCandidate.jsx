import React, { useState } from 'react';
import { Badge, Button, MONO } from '../primitives';
import { navigateTo } from '../../../utils/dashboardPath';
import {
  VERDICTS, candidateDraft, candidateEditPayload, candidateReplayPath, isOpenCandidate,
} from '../../../utils/explorations.mjs';

const STATE_TONES = { proposed: 'info', edited: 'info', accepted: 'success', rejected: 'muted' };

const fieldStyle = {
  width: '100%', boxSizing: 'border-box', padding: '6px 8px', borderRadius: 6, fontSize: 13, fontFamily: 'inherit',
  background: 'var(--color-card)', border: '1px solid var(--color-border-strong)', color: 'var(--color-text-primary)',
};

function Field({ label, children }) {
  return (
    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: 12, color: 'var(--color-text-secondary)' }}>
      {label}
      {children}
    </label>
  );
}

// One candidate in the "Found so far" list: its prompt, rubric, expected
// tools (the ones the agent lacks marked), verdict and how it was found,
// with its checkbox and the edit, reject and reconsider actions.
//
// `onSave(id, payload)` and `onState(id, state)` resolve once the request
// finished; `agentId` is the target agent's, for the needs-tool link.
export default function ExplorationCandidate({
  candidate, selected, onToggle, onSave, onState, busy, problem, agentId,
}) {
  const [draft, setDraft] = useState(null);
  const verdict = VERDICTS[candidate.verdict] || VERDICTS.unverified;
  const expectations = candidate.expectations || {};
  const missing = new Set(candidate.missing_tools || []);
  const provenance = candidate.provenance || {};
  const replayPath = candidateReplayPath(candidate);
  const open = isOpenCandidate(candidate);
  const set = (field) => (event) => setDraft({ ...draft, [field]: event.target.value });

  const save = async () => {
    if (await onSave(candidate.id, candidateEditPayload(draft))) setDraft(null);
  };

  return (
    <li
      data-testid={`exploration-candidate-${candidate.id}`}
      style={{ listStyle: 'none', padding: '12px 0', borderTop: '1px solid var(--color-border-light)', display: 'flex', gap: 10 }}
    >
      <input
        type="checkbox"
        aria-label={`Accept candidate ${candidate.id}`}
        checked={selected}
        disabled={!open || busy}
        onChange={() => onToggle(candidate.id)}
        style={{ marginTop: 3, alignSelf: 'flex-start' }}
      />
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 6 }}>
        <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
          <span style={{ fontSize: 14, fontWeight: 600, color: 'var(--color-text-primary)' }}>{candidate.prompt}</span>
          <Badge tone={verdict.tone} title={verdict.title} testId={`candidate-verdict-${candidate.id}`}>{verdict.label}</Badge>
          <Badge tone={STATE_TONES[candidate.state] || 'muted'}>{candidate.state}</Badge>
          {candidate.group && <Badge>{candidate.group}</Badge>}
          {candidate.scenario_key && <span style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>{candidate.scenario_key}</span>}
        </div>

        {draft ? (
          <div style={{ display: 'grid', gap: 8 }} data-testid={`candidate-edit-${candidate.id}`}>
            <Field label="Prompt"><input style={fieldStyle} value={draft.prompt} onChange={set('prompt')} /></Field>
            <Field label="Rubric: what a good answer does (the judge grades against it)">
              <textarea style={{ ...fieldStyle, minHeight: 60 }} value={draft.rubric} onChange={set('rubric')} />
            </Field>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: 8 }}>
              <Field label="Group"><input style={fieldStyle} value={draft.group} onChange={set('group')} /></Field>
              <Field label="Tools (comma-separated)"><input style={fieldStyle} value={draft.tools} onChange={set('tools')} /></Field>
              <Field label="Contains"><input style={fieldStyle} value={draft.contains} onChange={set('contains')} /></Field>
              <Field label="Does not contain"><input style={fieldStyle} value={draft.not_contains} onChange={set('not_contains')} /></Field>
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <Button size="sm" variant="primary" onClick={save} disabled={busy || !draft.prompt.trim()}>Save</Button>
              <Button size="sm" onClick={() => setDraft(null)} disabled={busy}>Cancel</Button>
            </div>
          </div>
        ) : (
          <>
            <div style={{ fontSize: 13, color: candidate.notes ? 'var(--color-text-cell)' : 'var(--color-text-muted)' }}>
              {candidate.notes || 'No rubric yet: the judge has nothing to grade the answer against.'}
            </div>
            {(expectations.tools?.length > 0 || expectations.contains?.length > 0 || expectations.not_contains?.length > 0) && (
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center', fontFamily: MONO, fontSize: 11 }}>
                {(expectations.tools || []).map((tool) => (
                  <Badge key={tool} tone={missing.has(tool) ? 'warning' : 'muted'} title={missing.has(tool) ? 'The agent cannot call this tool' : undefined}>
                    {missing.has(tool) ? `missing ${tool}` : tool}
                  </Badge>
                ))}
                {(expectations.contains || []).map((pattern) => <Badge key={`c-${pattern}`}>contains “{pattern}”</Badge>)}
                {(expectations.not_contains || []).map((pattern) => <Badge key={`n-${pattern}`}>not “{pattern}”</Badge>)}
              </div>
            )}
          </>
        )}

        {problem && <div style={{ fontSize: 12, color: 'var(--color-error-text)' }}>{problem}</div>}

        {(provenance.steps?.length > 0 || provenance.urls?.length > 0 || provenance.screenshots?.length > 0 || replayPath) && (
          <details style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>
            <summary style={{ cursor: 'pointer' }}>How it was found</summary>
            {provenance.urls?.length > 0 && (
              <div style={{ marginTop: 4, fontFamily: MONO, fontSize: 11 }}>{provenance.urls.join('  ·  ')}</div>
            )}
            {provenance.steps?.length > 0 && (
              <ol style={{ margin: '4px 0 0', paddingLeft: 18 }}>
                {provenance.steps.map((step, index) => <li key={index}>{step}</li>)}
              </ol>
            )}
            {provenance.screenshots?.length > 0 && (
              <div style={{ marginTop: 4, fontFamily: MONO, fontSize: 11 }}>Screenshots: {provenance.screenshots.join(', ')}</div>
            )}
          </details>
        )}

        {!draft && (
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {replayPath && (
              <Button size="sm" variant="ghost" onClick={() => navigateTo(replayPath)} testId={`candidate-replay-${candidate.id}`}>Replay</Button>
            )}
            {candidate.verdict === 'needs_tool' && agentId && (
              <Button size="sm" variant="ghost" onClick={() => navigateTo(`/agents/${agentId}/edit`)}>Give the agent the tool</Button>
            )}
            {candidate.state !== 'rejected' && (
              <Button size="sm" variant="ghost" onClick={() => setDraft(candidateDraft(candidate))} disabled={busy}>Edit</Button>
            )}
            {open && (
              <Button size="sm" variant="danger" onClick={() => onState(candidate.id, 'rejected')} disabled={busy}>Reject</Button>
            )}
            {candidate.state === 'rejected' && (
              <Button size="sm" variant="ghost" onClick={() => onState(candidate.id, 'proposed')} disabled={busy}>Reconsider</Button>
            )}
          </div>
        )}
      </div>
    </li>
  );
}
