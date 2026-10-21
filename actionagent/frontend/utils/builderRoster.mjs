import { entryKey } from './toolRoster.mjs';

// The agent builder's Configure step, read from GET /api/agents/tool_roster:
// the same rows the agent editor's Tools tab edits, for an agent not created
// yet. The builder offers only what a run would actually get — an MCP
// service a dashboard run cannot reach is named with the reason rather than
// offered as a chip.

// Switchable tools that give the model something: the toolbox's
// capabilities and the host's schema tools.
export function builderTools(payload) {
  return (payload?.tools || []).filter((tool) => tool.editable && tool.implemented !== false);
}

// The capabilities that act in the checkout sandbox a run is given
// (CheckoutTools): a run needs one chosen for them to do anything.
export const CHECKOUT_CAPABILITIES = ['terminal', 'filesystem', 'edit', 'database'];
export const checkoutToolsEnabled = (tools = []) => tools.some((tool) => CHECKOUT_CAPABILITIES.includes(tool));

// The functions with side effects outside the conversation, which wait for a
// person's approval by default when the builder enables their capability.
// The Tools tab's Approval switch lets them run without asking.
export const APPROVAL_BY_DEFAULT = {
  terminal: ['run_command'],
  filesystem: ['write_file'],
  edit: ['edit_file'],
  slack: ['slack_post_message'],
};

// The approval list for +tools+: the defaults of the capabilities enabled.
export const defaultApprovals = (tools = []) => [...new Set(tools.flatMap((tool) => APPROVAL_BY_DEFAULT[tool] || []))];

// The services a run can call, most used across the workspace first, and
// the ones it cannot, each with its reason.
export function builderServices(payload) {
  const services = payload?.services || [];
  const byUse = (a, b) => (b.workspace_agents || 0) - (a.workspace_agents || 0) || String(a.name).localeCompare(String(b.name));
  return {
    callable: services.filter((service) => service.callable).sort(byUse),
    unavailable: services.filter((service) => !service.callable),
  };
}

// +names+ narrowed to the tools the builder offers. Before the roster has
// loaded there is nothing to check against, so they are kept as given.
export function offeredTools(payload, names = []) {
  if (!payload) return [...names];
  const offered = new Set(builderTools(payload).map((tool) => tool.key));
  return names.filter((name) => offered.has(name));
}

export const serverEnabled = (servers = [], key) => servers.some((entry) => entryKey(entry) === key);

// Switches +service+ on or off in an agent's mcp_servers, writing the
// { key, name } shape the Tools tab saves (no tools list: every tool the
// server serves).
export function toggleServer(servers = [], service) {
  if (serverEnabled(servers, service.key)) return servers.filter((entry) => entryKey(entry) !== service.key);
  return [...servers, { key: service.key, name: service.name }];
}

// How many of the workspace's agents already enable a service, as a hint.
export function workspaceUseLabel(service) {
  const count = service.workspace_agents || 0;
  if (!count) return null;
  return `${count} agent${count === 1 ? '' : 's'}`;
}
