import React, { useCallback, useEffect, useState } from 'react';
import ExplorationList from './explorations/ExplorationList';
import ExplorationReview from './explorations/ExplorationReview';
import { Button, Card, PageHeader } from './primitives';
import { dashboardRelativePath, navigateTo } from '../../utils/dashboardPath';
import { apiErrorMessage } from '../../utils/codeSessions.mjs';
import { explorationPath, parseExplorationPath } from '../../utils/explorations.mjs';
import { projectPath } from '../../utils/projects.mjs';

// /explorations lists the owner's explorations, and /explorations/:id is
// one exploration's review, the page explorations_submit links to. The
// route table opens this view for every /explorations path; which page
// shows is read from the path here, on mount, on back/forward and on each
// in-app navigation (`visit`).
export default function ExplorationsView({ visit = 0 }) {
  const [route, setRoute] = useState(() => parseExplorationPath(dashboardRelativePath()));
  const [explorations, setExplorations] = useState(null);
  const [loaded, setLoaded] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    setRoute(parseExplorationPath(dashboardRelativePath()));
  }, [visit]);

  useEffect(() => {
    const applyPath = () => setRoute(parseExplorationPath(dashboardRelativePath()));
    window.addEventListener('popstate', applyPath);
    window.addEventListener('dashboard:navigate', applyPath);
    return () => {
      window.removeEventListener('popstate', applyPath);
      window.removeEventListener('dashboard:navigate', applyPath);
    };
  }, []);

  const loadExplorations = useCallback(async () => {
    try {
      const res = await fetch('/api/explorations');
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `Could not list explorations (HTTP ${res.status}).`));
      setExplorations(data.explorations || []);
    } catch (e) {
      setError(e.message);
    }
  }, []);

  useEffect(() => {
    if (!route.explorationId) loadExplorations();
  }, [route, loadExplorations]);

  if (route.explorationId) {
    const project = loaded?.project;
    const evaluation = loaded?.evaluation;
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
        <PageHeader
          crumbs={project
            ? [{ label: project.name, onClick: () => navigateTo(projectPath(project.id)) }]
            : [{ label: 'Explorations', onClick: () => navigateTo('/explorations') }]}
          title="Review candidate scenarios"
          actions={!project && evaluation ? (
            <Button size="sm" onClick={() => navigateTo(`/evaluations/${evaluation.id}`)}>Open {evaluation.name}</Button>
          ) : undefined}
        />
        <ExplorationReview key={route.explorationId} explorationId={route.explorationId} onLoaded={setLoaded} />
      </div>
    );
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      <PageHeader title="Explorations" />
      {error && <div style={{ fontSize: 13, color: 'var(--color-error-text)' }}>{error}</div>}
      {!error && !explorations && <div style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>Loading explorations…</div>}
      {explorations?.length === 0 && (
        <Card>
          <p style={{ margin: 0, fontSize: 14, color: 'var(--color-text-secondary)' }}>
            No explorations yet. An agent that explores a project's app submits what it found with the explorations_submit MCP tool.
          </p>
        </Card>
      )}
      {explorations?.length > 0 && (
        <ExplorationList explorations={explorations} onOpen={(exploration) => navigateTo(explorationPath(exploration.id))} />
      )}
    </div>
  );
}
