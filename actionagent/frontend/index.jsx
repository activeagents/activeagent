// Entry point for the mounted dashboard.
//
// The engine hands initial state over as a JSON data attribute rather than
// through Inertia, so a host app can mount this without adopting a frontend
// framework of its own.
import React from 'react';
import { createRoot } from 'react-dom/client';
import Dashboard from './pages/Dashboard';
import { installApiFetch } from './utils/apiFetch.mjs';

const MOUNT_ID = 'active-agent-dashboard';

function mount() {
  const node = document.getElementById(MOUNT_ID);
  if (!node) return;

  const props = JSON.parse(node.dataset.props || '{}');
  window.ACTIVE_AGENT_DASHBOARD = props;
  // Components fetch absolute "/api/..." paths; this puts them on the
  // engine's mount and attaches the CSRF token (see utils/apiFetch.mjs).
  installApiFetch(props.mountPath || '/');

  createRoot(node).render(<Dashboard {...props} />);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', mount);
} else {
  mount();
}
