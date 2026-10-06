import React, { useCallback, useEffect, useState } from 'react';
import NewProject from './projects/NewProject';
import ProjectDetail from './projects/ProjectDetail';
import ProjectList from './projects/ProjectList';
import { dashboardRelativePath, pushDashboardPath } from '../../utils/dashboardPath';
import { apiErrorMessage } from '../../utils/codeSessions.mjs';
import { parseProjectPath, projectPath } from '../../utils/projects.mjs';

// Projects: the list, the New Project page (/projects/new) and a project's
// page (/projects/:id). The route table opens this view for every /projects
// path; which page shows is read from the path here, on mount and on
// back/forward.
//
// visit changes each time the dashboard navigates in-app, which re-reads the
// path too.
export default function ProjectsView({ visit = 0 }) {
  const [route, setRoute] = useState(() => parseProjectPath(dashboardRelativePath()));
  const [projects, setProjects] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    setRoute(parseProjectPath(dashboardRelativePath()));
  }, [visit]);

  useEffect(() => {
    const applyPath = () => setRoute(parseProjectPath(dashboardRelativePath()));
    window.addEventListener('popstate', applyPath);
    window.addEventListener('dashboard:navigate', applyPath);
    return () => {
      window.removeEventListener('popstate', applyPath);
      window.removeEventListener('dashboard:navigate', applyPath);
    };
  }, []);

  const loadProjects = useCallback(async () => {
    try {
      const res = await fetch('/api/projects');
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `Could not list projects (HTTP ${res.status}).`));
      setProjects(data.projects || []);
    } catch (e) {
      setError(e.message);
    }
  }, []);

  useEffect(() => {
    if (!route.creating && !route.projectId) loadProjects();
  }, [route, loadProjects]);

  const go = (path) => {
    pushDashboardPath(path);
    setRoute(parseProjectPath(path));
  };

  if (route.creating) {
    return <NewProject onCreated={(project) => go(projectPath(project.id))} onCancel={() => go('/projects')} />;
  }
  if (route.projectId) {
    return <ProjectDetail key={route.projectId} projectId={route.projectId} onBack={() => go('/projects')} onDeleted={() => go('/projects')} />;
  }
  if (error) return <div style={{ fontSize: 13, color: 'var(--color-error-text)' }}>{error}</div>;
  if (!projects) return <div style={{ fontSize: 13, color: 'var(--color-text-secondary)' }}>Loading projects…</div>;

  return <ProjectList projects={projects} onOpen={(project) => go(projectPath(project.id))} onNew={() => go(projectPath(null))} />;
}
