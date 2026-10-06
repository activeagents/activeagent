import React, { useCallback, useEffect, useState } from 'react';
import ExplorationList from './explorations/ExplorationList';
import ExplorationReview from './explorations/ExplorationReview';
import { Button, Card } from './primitives';
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
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          {project ? (
            <Button size="sm" variant="ghost" onClick={() => navigateTo(projectPath(project.id))} style={{ padding: 0 }}>← {project.name}</Button>
          ) : (
            <Button size="sm" variant="ghost" onClick={() => navigateTo('/explorations')} style={{ padding: 0 }}>← Explorations</Button>
          )}
          {!project && evaluation && (
            <Button size="sm" variant="ghost" onClick={() => navigateTo(`/evaluations/${evaluation.id}`)}>Open {evaluation.name}</Button>
          )}
        </div>
        <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>
          Review candidate scenarios
        </h1>
        <ExplorationReview key={route.explorationId} explorationId={route.explorationId} onLoaded={setLoaded} />
      </div>
    );
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      <div>
        <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>Explorations</h1>
        <p style={{ margin: '4px 0 0', fontSize: 14, color: 'var(--color-text-secondary)' }}>
          Questions found by walking an app, waiting to be reviewed and accepted into an evaluation.
        </p>
      </div>
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
