import React from 'react';
import { Badge, Button, Card, MicroLabel } from '../primitives';
import CodeSessionPanel from '../CodeSessionPanel';
import { dashboardPath, navigateTo } from '../../../utils/dashboardPath';
import { conversationPath } from '../../../utils/codeConversations.mjs';
import { codeSessionStatus } from '../../../utils/codeSessions.mjs';
import { canAskSetup, canFixWithClaudeCode, claudeCodeFixText, setupStatusText } from '../../../utils/projectSetup.mjs';

const RUN_TONES = { awaiting_input: 'warning', running: 'info', pending: 'info', complete: 'success', failed: 'error' };
// A code session's tones (codeSessionStatus) as Badge tones.
const SESSION_TONES = { progress: 'info', success: 'success', error: 'error', neutral: 'muted' };

// What helps a failed boot, and what it is doing: Claude Code, which fixes
// the failed step in the checkout and resumes the boot, when the owner's
// Claude Code is connected (its session follows below, as it runs); the
// setup assistant, which sets variables and asks for secrets, otherwise.
// Each says whether it can run and, when not, why. Without either, the
// Environment tab stays the way to set what the boot needs, and the card
// says so.
export default function ProjectSetupCard({ project, busy, onAsk, onFixWithClaudeCode, onToggleAuto }) {
  const setup = project?.setup;
  if (!setup) return null;
  const run = setup.last_run;
  const claudeCode = setup.claude_code;
  const session = claudeCode?.last_session;

  return (
    <Card testId="project-setup">
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <MicroLabel>Setup</MicroLabel>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignItems: 'center' }}>
          <label style={{ display: 'flex', gap: 6, alignItems: 'center', fontSize: 12, color: 'var(--color-text-secondary)' }}>
            <input type="checkbox" checked={setup.auto !== false} disabled={busy} onChange={(event) => onToggleAuto(event.target.checked)} />
            Start it when a boot fails
          </label>
        </span>
      </div>

      {claudeCode && (
        <div data-testid="project-setup-claude-code" style={{ marginTop: 10 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)' }}>Claude Code</span>
            {!claudeCode.available && !session && <Badge tone="muted">not used</Badge>}
            {session && <Badge tone={SESSION_TONES[codeSessionStatus(session.status).tone] || 'muted'}>{codeSessionStatus(session.status).label}</Badge>}
            {canFixWithClaudeCode(project) && onFixWithClaudeCode && (
              <Button size="sm" variant="primary" onClick={onFixWithClaudeCode} disabled={busy} testId="fix-with-claude-code" style={{ marginLeft: 'auto' }}>
                Fix the boot with Claude Code
              </Button>
            )}
          </div>
          <p data-testid="claude-code-status" style={{ margin: '4px 0 0', fontSize: 13, color: 'var(--color-text-secondary)' }}>{claudeCodeFixText(project)}</p>
          {session?.id && (
            <a
              href={dashboardPath(conversationPath(session.id))}
              onClick={(event) => { event.preventDefault(); navigateTo(conversationPath(session.id)); }}
              data-testid="boot-fix-conversation"
              style={{ display: 'inline-block', marginTop: 4, fontSize: 12, color: 'var(--color-accent-ui)' }}
            >
              Ask Claude Code about this fix →
            </a>
          )}
          {session?.sandbox_session_id && (
            <CodeSessionPanel
              sandbox={{ session_id: session.sandbox_session_id }}
              readOnly
              focusSessionId={session.id}
              title={`Claude Code on ${claudeCode.failed_step || 'the boot'}`}
            />
          )}
        </div>
      )}

      <div style={{ marginTop: 12 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)' }}>Setup assistant</span>
          {!setup.available && <Badge tone="muted">unavailable</Badge>}
          {run && <Badge tone={RUN_TONES[run.status] || 'muted'}>{run.status.replace('_', ' ')}</Badge>}
          <span style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignItems: 'center' }}>
            {setup.agent_id && run && (
              <Button size="sm" variant="ghost" onClick={() => navigateTo(`/agents/${setup.agent_id}/interactions`)}>Open its runs</Button>
            )}
            {canAskSetup(project) && (
              <Button size="sm" variant={canFixWithClaudeCode(project) ? 'secondary' : 'primary'} onClick={onAsk} disabled={busy} testId="ask-setup-assistant">
                Ask the setup assistant
              </Button>
            )}
          </span>
        </div>
        <p style={{ margin: '4px 0 0', fontSize: 13, color: 'var(--color-text-secondary)' }}>
          {setupStatusText(setup)}
          {!setup.available && ' Set the variables the boot needs in the Environment tab.'}
          {setup.available && claudeCode?.available && ' Claude Code goes first when a boot fails; the setup assistant is the fallback.'}
        </p>
        <p style={{ margin: '4px 0 0', fontSize: 12, color: 'var(--color-text-muted)' }}>
          It reads the failed step&apos;s log, sets variables that are not secret, asks you for secrets, and retries the boot. It runs no
          commands and reads no files.
        </p>
      </div>
    </Card>
  );
}
