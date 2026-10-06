import React, { useCallback, useEffect, useState } from 'react';
import { Button, Card } from '../primitives';
import ExplorationList from '../explorations/ExplorationList';
import ExplorationReview from '../explorations/ExplorationReview';
import ExplorerStart from './ExplorerStart';
import ProjectSignIn from './ProjectSignIn';
import { navigateTo } from '../../../utils/dashboardPath';
import { apiErrorMessage } from '../../../utils/codeSessions.mjs';
import { explorationPath } from '../../../utils/explorations.mjs';

// A project's Explorations tab: starting the explorer and how it signs in,
// then the project's explorations, newest first, with the chosen one's
// review below them (the newest until another is picked).
export default function ProjectExplorations({ projectId, project, onCount }) {
  const [explorations, setExplorations] = useState(null);
  const [selectedId, setSelectedId] = useState(null);
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    const res = await fetch(`/api/explorations?project_id=${projectId}`);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(apiErrorMessage(data, `Could not list the project's explorations (HTTP ${res.status}).`));
    setExplorations(data.explorations || []);
    onCount?.(data.explorations?.length || 0);
  }, [projectId, onCount]);

  useEffect(() => {
    load().catch((e) => setError(e.message));
  }, [load]);

  const sandboxReady = project?.sandbox_state === 'ready';
  const setup = (
    <>
      <ExplorerStart
        projectId={projectId}
        sandboxReady={sandboxReady}
        onStarted={(exploration) => {
          setSelectedId(exploration.id);
          load().catch((e) => setError(e.message));
        }}
      />
      <ProjectSignIn projectId={projectId} sandboxId={project?.sandbox?.session_id} sandboxReady={sandboxReady} />
    </>
  );

  if (error) return <div style={{ fontSize: 13, color: 'var(--color-error-text)' }}>{error}</div>;
  if (!explorations) return <div style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>Loading explorations…</div>;
  if (explorations.length === 0) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
        {setup}
        <Card testId="project-explorations-empty">
          <p style={{ margin: 0, fontSize: 14, color: 'var(--color-text-secondary)' }}>
            No explorations yet. Explore the app above, or have an agent that explores it, such as a coding agent driving a
            browser, submit the questions it found with the explorations_submit MCP tool. They are reviewed here before any
            reaches the evaluation.
          </p>
        </Card>
      </div>
    );
  }

  const current = selectedId || explorations[0].id;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }} data-testid="project-explorations">
      {setup}
      <ExplorationList explorations={explorations} selectedId={current} onOpen={(exploration) => setSelectedId(exploration.id)} />
      <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
        <Button size="sm" variant="ghost" onClick={() => navigateTo(explorationPath(current))}>Open on its own page</Button>
      </div>
      <ExplorationReview key={current} explorationId={current} onLoaded={() => load().catch(() => {})} />
    </div>
  );
}
