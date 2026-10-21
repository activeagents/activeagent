import assert from 'node:assert/strict';
import test from 'node:test';
import {
  builderServices,
  builderTools,
  checkoutToolsEnabled,
  defaultApprovals,
  offeredTools,
  serverEnabled,
  toggleServer,
  workspaceUseLabel,
} from '../utils/builderRoster.mjs';

// GET /api/agents/tool_roster, trimmed to the fields the builder reads.
const ROSTER = {
  tools: [
    { key: 'find_posts', name: 'find_posts', source: 'agent_defined', editable: true, enabled: false },
    { key: 'refund_invoice', name: 'refund_invoice', source: 'agent_defined', editable: false, enabled: true },
    { key: 'fetch', name: 'fetch', source: 'dashboard', editable: true, implemented: true },
    { key: 'code', name: 'code', source: 'dashboard', editable: true, implemented: true },
    { key: 'terminal', name: 'terminal', source: 'dashboard', editable: true, implemented: false },
    { key: 'slack', name: 'slack', source: 'dashboard', editable: true, implemented: false },
  ],
  services: [
    { key: 'playwright', name: 'Playwright', callable: false, unavailable_reason: 'stdio server', workspace_agents: 3 },
    { key: 'tickets', name: 'Tickets', callable: true, workspace_agents: 1 },
    { key: 'crm', name: 'CRM', callable: true, workspace_agents: 2 },
    { key: 'sandbox:abc', name: 'app@main (sandbox)', callable: true, runtime: true, workspace_agents: 0 },
  ],
};

test('the builder offers switchable tools that do something', () => {
  assert.deepEqual(builderTools(ROSTER).map((tool) => tool.key), ['find_posts', 'fetch', 'code']);
});

test('side-effecting functions wait for approval by default, and checkout tools need a checkout', () => {
  assert.deepEqual(defaultApprovals(['terminal', 'fetch', 'edit', 'slack']), ['run_command', 'edit_file', 'slack_post_message']);
  assert.deepEqual(defaultApprovals(['code']), []);
  assert.ok(checkoutToolsEnabled(['fetch', 'database']));
  assert.ok(!checkoutToolsEnabled(['fetch', 'slack']));
});

test('services split into callable, most used first, and the rest with their reason', () => {
  const { callable, unavailable } = builderServices(ROSTER);
  assert.deepEqual(callable.map((service) => service.key), ['crm', 'tickets', 'sandbox:abc']);
  assert.deepEqual(unavailable.map((service) => service.unavailable_reason), ['stdio server']);
});

test('a preset or draft selection is narrowed to what the roster offers, once it has loaded', () => {
  assert.deepEqual(offeredTools(ROSTER, ['terminal', 'code', 'refund_invoice', 'find_posts']), ['code', 'find_posts']);
  assert.deepEqual(offeredTools(null, ['terminal', 'code']), ['terminal', 'code']);
});

test('toggling a service writes the Tools tab shape and removes either shape', () => {
  const tickets = ROSTER.services[1];
  const on = toggleServer([], tickets);
  assert.deepEqual(on, [{ key: 'tickets', name: 'Tickets' }]);
  assert.ok(serverEnabled(on, 'tickets'));
  assert.deepEqual(toggleServer(on, tickets), []);
  assert.deepEqual(toggleServer(['tickets', 'crm'], tickets), ['crm']);
});

test('workspace use reads as a count of agents, or nothing', () => {
  assert.equal(workspaceUseLabel({ workspace_agents: 1 }), '1 agent');
  assert.equal(workspaceUseLabel({ workspace_agents: 4 }), '4 agents');
  assert.equal(workspaceUseLabel({ workspace_agents: 0 }), null);
});
