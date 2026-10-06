import React from 'react';
import { Badge, Button, Card, MicroLabel } from '../primitives';
import { navigateTo } from '../../../utils/dashboardPath';
import { canAskSetup, setupStatusText } from '../../../utils/projectSetup.mjs';

const RUN_TONES = { awaiting_input: 'warning', running: 'info', pending: 'info', complete: 'success', failed: 'error' };

// The project's setup assistant: whether it can run (and why not), whether a
// failed boot starts it on its own, its latest run, and Ask the setup
// assistant on a failed boot. Without a provider key the Environment tab
// stays the way to set what the boot needs, and the card says so.
export default function ProjectSetupCard({ project, busy, onAsk, onToggleAuto }) {
  const setup = project?.setup;
  if (!setup) return null;
  const run = setup.last_run;

  return (
    <Card testId="project-setup">
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <MicroLabel>Setup assistant</MicroLabel>
        {!setup.available && <Badge tone="muted">unavailable</Badge>}
        {run && <Badge tone={RUN_TONES[run.status] || 'muted'}>{run.status.replace('_', ' ')}</Badge>}
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignItems: 'center' }}>
          <label style={{ display: 'flex', gap: 6, alignItems: 'center', fontSize: 12, color: 'var(--color-text-secondary)' }}>
            <input type="checkbox" checked={setup.auto !== false} disabled={busy} onChange={(event) => onToggleAuto(event.target.checked)} />
            Start it when a boot fails
          </label>
          {setup.agent_id && run && (
            <Button size="sm" variant="ghost" onClick={() => navigateTo(`/agents/${setup.agent_id}/interactions`)}>Open its runs</Button>
          )}
          {canAskSetup(project) && (
            <Button size="sm" variant="primary" onClick={onAsk} disabled={busy} testId="ask-setup-assistant">Ask the setup assistant</Button>
          )}
        </span>
      </div>
      <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--color-text-secondary)' }}>
        {setupStatusText(setup)}
        {!setup.available && ' Set the variables the boot needs in the Environment tab.'}
      </p>
      <p style={{ margin: '4px 0 0', fontSize: 12, color: 'var(--color-text-muted)' }}>
        It reads the failed step&apos;s log, sets variables that are not secret, asks you for secrets, and retries the boot. It runs no
        commands and reads no files.
      </p>
    </Card>
  );
}
