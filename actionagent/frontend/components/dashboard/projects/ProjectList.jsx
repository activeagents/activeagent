import React from 'react';
import { Badge, Button, Card, MONO } from '../primitives';

const STATE_TONES = { ready: 'success', booting: 'info', failed: 'error', expired: 'muted', none: 'muted' };

// The projects index: one row per project (GET /api/projects), newest first.
export default function ProjectList({ projects, onOpen, onNew }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }} data-testid="project-list">
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 16 }}>
        <div style={{ flex: 1 }}>
          <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>Projects</h1>
          <p style={{ margin: '4px 0 0', fontSize: 14, color: 'var(--color-text-secondary)' }}>
            A repository booted in a sandbox, with the secrets it needs and an agent evaluated against the running app.
          </p>
        </div>
        <Button variant="primary" onClick={onNew} testId="new-project-button">New project</Button>
      </div>

      {projects.length === 0 && (
        <Card>
          <p style={{ margin: 0, fontSize: 14, color: 'var(--color-text-secondary)' }}>
            No projects yet. Pick a repository to boot it in a sandbox, even one that does not use ActiveAgent.
          </p>
        </Card>
      )}

      {projects.map((project) => (
        <Card key={project.id} padding={14} testId={`project-${project.id}`}>
          <button
            type="button"
            onClick={() => onOpen(project)}
            style={{ all: 'unset', cursor: 'pointer', display: 'flex', gap: 10, alignItems: 'center', width: '100%', flexWrap: 'wrap' }}
          >
            <span style={{ fontSize: 15, fontWeight: 600, color: 'var(--color-text-primary)' }}>{project.name}</span>
            <span style={{ fontFamily: MONO, fontSize: 12, color: 'var(--color-text-muted)' }}>{project.repository}</span>
            <span style={{ marginLeft: 'auto', display: 'flex', gap: 6 }}>
              <Badge tone={STATE_TONES[project.sandbox_state] || 'muted'}>sandbox {project.sandbox_state}</Badge>
              {project.target_agent && <Badge tone="accent">{project.target_agent.kind === 'app_assistant' ? 'App assistant' : project.target_agent.synced_agent}</Badge>}
            </span>
          </button>
        </Card>
      ))}
    </div>
  );
}
