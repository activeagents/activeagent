import { mountedPath } from './mountPath.mjs';

// What an app needs to report its traces to this dashboard: the endpoint and
// the config/active_agent.yml block that points at it. The Organization
// page's Telemetry card and the empty agent list both show it.

// The trace ingest URL. A multi-tenant platform serves its collector at
// /v1/traces on its own host; a self-hosted install takes traces at the
// engine's <mount>/api/traces.
export function telemetryEndpoint({ origin, mountPath, multiTenant }) {
  return multiTenant ? `${origin}/v1/traces` : `${origin}${mountedPath(mountPath, '/api/traces')}`;
}

// The telemetry block for config/active_agent.yml. The key is read from the
// environment, never written into the file.
export function telemetryConfigSnippet(endpoint) {
  return `telemetry:
  enabled: true
  endpoint: ${endpoint}
  api_key: <%= ENV["ACTIVEAGENTS_API_KEY"] %>`;
}

// The endpoint for the dashboard on this page.
export function currentTelemetryEndpoint() {
  const dashboard = window.ACTIVE_AGENT_DASHBOARD || {};
  return telemetryEndpoint({
    origin: window.location.origin,
    mountPath: dashboard.mountPath,
    multiTenant: Boolean(dashboard.meta?.multiTenant),
  });
}
