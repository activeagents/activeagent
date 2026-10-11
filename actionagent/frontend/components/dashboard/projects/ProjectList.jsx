import React from 'react';
import { Badge, Button, Card, MONO, PageHeader } from '../primitives';

const STATE_TONES = { ready: 'success', booting: 'info', failed: 'error', expired: 'muted', none: 'muted' };

// The projects index: one row per project (GET /api/projects), newest first.
export default function ProjectList({ projects, onOpen, onNew }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }} data-testid="project-list">
      <PageHeader
        title="Projects"
        actions={<Button variant="primary" onClick={onNew} testId="new-project-button">New project</Button>}
      />

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
