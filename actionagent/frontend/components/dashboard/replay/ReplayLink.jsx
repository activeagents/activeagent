import React from 'react';
import { MONO } from '../primitives';
import { dashboardPath, navigateTo } from '../../../utils/dashboardPath';
import { sessionReplayPath } from '../../../utils/dashboardRoutes.mjs';

// A "replay ->" link to a session's replay (see sessionReplayPath). It
// opens in the dashboard, or in a new tab with a modifier key, and never
// reaches a clickable row it sits in. Renders nothing for a session that
// has no replay path.
export default function ReplayLink({ kind, id, title = 'Replay this session', testId = 'replay-link', style }) {
  const path = sessionReplayPath(kind, id);
  if (!path) return null;

  return (
    <a
      href={dashboardPath(path)}
      data-testid={testId}
      title={title}
      onClick={(event) => {
        event.stopPropagation();
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return;
        event.preventDefault();
        navigateTo(path);
      }}
      style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-info)', textDecoration: 'none', whiteSpace: 'nowrap', ...style }}
    >
      replay -&gt;
    </a>
  );
}
