// The request behind the Traces view.
//
// Kept apart from the component so it can be tested directly.

// Returns the /api/traces path for the last +minutes+, narrowed to one agent's
// traces when +agentId+ is given. The agent is named by id rather than by
// class: the server selects its traces from the record, because an observed
// agent's traces carry the application's own class name and one class can
// belong to several agents, one per action.
export const tracesQuery = ({ minutes, agentId = null }) => {
  const params = new URLSearchParams({ minutes: String(minutes) });
  if (agentId != null && agentId !== '') params.set('agent_id', String(agentId));
  return `/api/traces?${params.toString()}`;
};
