// "New interaction": which agents a person can start a conversation with,
// and where that conversation opens.

// Archived agents are kept for their history and are not run, and an
// observed one was reconstructed from telemetry, with nothing a dashboard run
// could execute unless it names a reachable server — its own page is where
// that is sorted out, not a picker. The rest are
// listed active first, then by name, narrowed by a case-insensitive match on
// the name or description.
export function startableAgents(agents = [], query = '') {
  const needle = query.trim().toLowerCase();
  return agents
    .filter((agent) => agent.status !== 'archived' && agent.status !== 'observed')
    .filter((agent) => !needle || `${agent.name || ''} ${agent.description || ''}`.toLowerCase().includes(needle))
    .sort((a, b) => {
      const rank = (agent) => (agent.status === 'active' ? 0 : 1);
      return rank(a) - rank(b) || String(a.name || '').localeCompare(String(b.name || ''));
    });
}

// The agent's runner, opened on an empty conversation (AgentRunner's
// freshConversation) instead of its latest one.
export const newInteractionPath = (agent) => `/agents/${agent.id}/run?new=1`;
