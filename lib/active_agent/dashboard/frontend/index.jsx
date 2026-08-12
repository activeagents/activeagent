// Entry point for the mounted dashboard.
//
// The engine hands initial state over as a JSON data attribute rather than
// through Inertia, so a host app can mount this without adopting a frontend
// framework of its own.
import React from 'react';
import { createRoot } from 'react-dom/client';
import Dashboard from './pages/Dashboard';

const MOUNT_ID = 'active-agent-dashboard';

// The engine can be mounted anywhere ("/activeagents", "/admin/agents", the
// root of a subdomain). Components fetch absolute "/api/..." paths, so
// same-origin API requests are rewritten onto the mount here — one shim
// instead of threading a base path through every component.
function installFetchBasePath(mountPath) {
  const base = mountPath.replace(/\/$/, '');
  if (!base) return;

  const original = window.fetch.bind(window);
  window.fetch = (input, init) => {
    if (typeof input === 'string' && input.startsWith('/api/')) {
      return original(`${base}${input}`, init);
    }
    if (input instanceof Request && new URL(input.url, window.location.origin).pathname.startsWith('/api/')) {
      const url = new URL(input.url, window.location.origin);
      return original(new Request(`${base}${url.pathname}${url.search}`, input), init);
    }
    return original(input, init);
  };
}

function mount() {
  const node = document.getElementById(MOUNT_ID);
  if (!node) return;

  const props = JSON.parse(node.dataset.props || '{}');
  window.ACTIVE_AGENT_DASHBOARD = props;
  installFetchBasePath(props.mountPath || '/');

  createRoot(node).render(<Dashboard {...props} />);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', mount);
} else {
  mount();
}
