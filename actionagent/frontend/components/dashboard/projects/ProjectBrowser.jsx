import React from 'react';
import BrowserPanel from '../BrowserPanel';
import { MONO, MonoLink, Panel } from '../primitives';
import { dashboardPath, navigateTo } from '../../../utils/dashboardPath';

const RUNTIMES_PATH = '/settings?tab=integrations';

// The project's Browser tab: its sandbox's browser (BrowserPanel), started,
// stopped and watched live from here, with Take over and file uploads, as on
// Settings -> Integrations, which still lists every runtime. `modes` is what
// the backend can start; `watchOnOpen` starts watching once the live view
// is there, for the header's Watch live; `onChange` follows a start or stop.
export default function ProjectBrowser({ project, modes = [], watchOnOpen = false, onChange }) {
  const sandbox = project.sandbox;
  const ready = project.sandbox_state === 'ready' && Boolean(sandbox?.session_id);
  const note = { margin: 0, fontSize: 13, color: 'var(--color-text-secondary)' };

  let body;
  if (modes.length === 0) {
    body = <p style={note}>This dashboard's sandbox backend runs no browsers. The project's agent works through the app's tools.</p>;
  } else if (!ready) {
    body = <p style={note}>Boot the sandbox to start its browser. It opens on the running app, and you can watch it live and take over.</p>;
  } else {
    body = (
      <>
        <p style={note}>
          A browser of the sandbox's own, opened on {project.repository}'s running app. Watch it live, take over to click, type and
          upload files, and hand back. Agent runs reach it as <span style={{ fontFamily: MONO }}>browser:{sandbox.session_id}</span>.
        </p>
        <BrowserPanel key={sandbox.session_id} sandbox={sandbox} modes={modes} watchOnOpen={watchOnOpen} onChange={onChange} />
      </>
    );
  }

  return (
    <Panel
      title="Browser"
      meta={<MonoLink href={dashboardPath(RUNTIMES_PATH)} onClick={() => navigateTo(RUNTIMES_PATH)}>Manage runtimes</MonoLink>}
      testId="project-browser"
      bodyStyle={{ padding: 12, display: 'flex', flexDirection: 'column', gap: 8 }}
    >
      {body}
    </Panel>
  );
}
