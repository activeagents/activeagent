import React, { useCallback, useEffect, useState } from 'react';
import { Badge, Button, Card, MicroLabel, MONO } from '../primitives';
import { dashboardPath, navigateTo } from '../../../utils/dashboardPath';
import { apiErrorMessage, codeSessionStatus } from '../../../utils/codeSessions.mjs';
import { codeRootId, conversationLine, conversationPath } from '../../../utils/codeConversations.mjs';

const TONES = { success: 'success', error: 'error', progress: 'info', neutral: 'muted' };

// The project's Sessions tab: its Claude Code and Codex conversations, each
// opening as an interaction with its composer and the sandbox's browser, and
// a box to start a new one in the project's ready checkout.
export default function ProjectSessions({ project }) {
  const [conversations, setConversations] = useState(null);
  const [error, setError] = useState(null);
  const [draft, setDraft] = useState('');
  const [starting, setStarting] = useState(false);
  const sandbox = project.sandbox;
  const ready = project.sandbox_state === 'ready' && Boolean(sandbox?.session_id);

  const load = useCallback(async () => {
    const res = await fetch(`/api/interactions?project_id=${project.id}`);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      setError(apiErrorMessage(data, `Could not list the conversations (HTTP ${res.status}).`));
      return;
    }
    setConversations(data.interactions || []);
  }, [project.id]);

  useEffect(() => { void load(); }, [load]);

  const start = async (event) => {
    event.preventDefault();
    const prompt = draft.trim();
    if (!prompt || !ready) return;
    setStarting(true);
    setError(null);
    try {
      const res = await fetch(`/api/sandboxes/${encodeURIComponent(sandbox.session_id)}/code_sessions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt, origin: 'chat' }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `The conversation did not start (HTTP ${res.status}).`));
      navigateTo(conversationPath(data.code_session.id));
    } catch (e) {
      setError(e.message);
      setStarting(false);
    }
  };

  const note = { margin: 0, fontSize: 13, color: 'var(--color-text-secondary)' };

  return (
    <div style={{ display: 'grid', gap: 12 }} data-testid="project-sessions">
      <Card>
        <form onSubmit={start} style={{ display: 'grid', gap: 8 }}>
          <MicroLabel as="label" htmlFor={`project-${project.id}-chat`}>Chat with Claude Code</MicroLabel>
          <textarea
            id={`project-${project.id}-chat`}
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            rows={3}
            disabled={!ready}
            placeholder={ready ? `What should Claude Code do in ${project.repository}?` : 'Boot the sandbox to start a conversation'}
            style={{ width: '100%', fontSize: 13, padding: 8, borderRadius: 6, border: '1px solid var(--color-border)', background: 'var(--color-surface)', color: 'var(--color-text-primary)' }}
          />
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8 }}>
            <p style={note}>
              It edits the checkout and never commits or pushes. The conversation opens with the sandbox's browser beside it.
            </p>
            <Button variant="primary" type="submit" disabled={!ready || starting || !draft.trim()} testId="project-start-conversation">
              {starting ? 'Starting…' : 'Start'}
            </Button>
          </div>
          {error && <p role="alert" style={{ ...note, color: 'var(--color-error-text)' }}>{error}</p>}
        </form>
      </Card>

      <Card>
        <MicroLabel>Conversations</MicroLabel>
        {conversations === null && !error && <p style={note}>Loading…</p>}
        {conversations?.length === 0 && <p style={note}>No conversations yet.</p>}
        <ul style={{ listStyle: 'none', margin: '8px 0 0', padding: 0, display: 'grid', gap: 8 }}>
          {(conversations || []).map((row) => {
            const status = codeSessionStatus(row.status);
            const path = conversationPath(codeRootId(row.id));
            return (
              <li key={row.id}>
                <a
                  href={dashboardPath(path)}
                  onClick={(event) => { event.preventDefault(); navigateTo(path); }}
                  style={{ display: 'grid', gap: 2, textDecoration: 'none', color: 'var(--color-text-primary)' }}
                  data-testid="project-conversation"
                >
                  <span style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                    <Badge tone={TONES[status.tone] || 'muted'}>{status.label}</Badge>
                    <span style={{ fontSize: 13 }}>{row.preview?.input || row.display_name}</span>
                  </span>
                  <span style={{ fontSize: 12, color: 'var(--color-text-secondary)', fontFamily: MONO }}>{conversationLine(row)}</span>
                </a>
              </li>
            );
          })}
        </ul>
      </Card>
    </div>
  );
}
