import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Badge, Button, Card, Empty, MicroLabel, MONO } from './primitives';
import { navigateTo } from '../../utils/dashboardPath';
import { newInteractionPath, startableAgents } from '../../utils/newInteraction.mjs';

// Starting a conversation with one of the workspace's agents, from wherever
// the person is looking at conversations (Interactions) or running agents
// (Sandbox). Either way it lands on the agent's runner with an empty
// conversation, so the run gets the instructions, tools and MCP servers
// saved on the agent — the same ones its Tools tab shows.
//
// +inline+ lists the agents in a card; otherwise a button opens the list as
// a popover.
export default function NewInteractionPicker({ inline = false, label = 'New interaction' }) {
  const [open, setOpen] = useState(inline);
  const [agents, setAgents] = useState(null);
  const [error, setError] = useState(null);
  const [query, setQuery] = useState('');
  const rootRef = useRef(null);

  useEffect(() => {
    if (!open || agents) return;
    fetch('/api/agents')
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json();
      })
      .then((data) => setAgents(data.agents || []))
      .catch((err) => setError(err.message));
  }, [open, agents]);

  // A popover closes on a click outside it.
  useEffect(() => {
    if (inline || !open) return undefined;
    const close = (event) => { if (rootRef.current && !rootRef.current.contains(event.target)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [inline, open]);

  const shown = useMemo(() => startableAgents(agents || [], query), [agents, query]);

  const list = (
    <div data-testid="new-interaction-agents">
      {(agents?.length || 0) > 6 && (
        <input
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Find an agent"
          aria-label="Find an agent"
          autoFocus={!inline}
          className="w-full mb-2 px-3 py-1.5 text-sm rounded-lg"
          style={{ background: 'var(--color-muted)', border: '1px solid var(--color-border)', color: 'var(--color-text-primary)' }}
        />
      )}
      {error && <p className="text-sm" style={{ color: 'var(--color-error)' }}>Could not load agents: {error}</p>}
      {!agents && !error && <p className="text-sm" style={{ color: 'var(--color-text-muted)' }}>Loading agents…</p>}
      {agents && shown.length === 0 && (
        <Empty>
          {agents.length === 0 ? 'No agents in this workspace yet.' : 'No agent matches.'}{' '}
          <a
            href="#"
            onClick={(event) => { event.preventDefault(); navigateTo('/agents/new'); }}
            style={{ color: 'var(--color-info)' }}
          >
            Create an agent
          </a>
        </Empty>
      )}
      <ul className="space-y-1 max-h-80 overflow-y-auto">
        {shown.map((agent) => (
          <li key={agent.id}>
            <button
              type="button"
              data-testid={`new-interaction-agent-${agent.id}`}
              onClick={() => navigateTo(newInteractionPath(agent))}
              className="w-full text-left px-3 py-2 rounded-lg block"
              style={{ border: '1px solid var(--color-border)', background: 'var(--color-card)', cursor: 'pointer' }}
            >
              <span className="flex items-center justify-between gap-2">
                <span className="text-sm font-medium truncate min-w-0" style={{ color: 'var(--color-text-primary)' }}>{agent.name}</span>
                {agent.status && agent.status !== 'active' && <Badge tone="muted">{agent.status}</Badge>}
              </span>
              <span className="block truncate" style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
                {agent.provider}/{agent.model}
              </span>
              {agent.description && (
                <span className="block text-xs truncate" style={{ color: 'var(--color-text-secondary)' }}>{agent.description}</span>
              )}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );

  if (inline) {
    return (
      <Card testId="new-interaction-card">
        <div className="flex items-baseline justify-between mb-3 gap-3">
          <div>
            <MicroLabel>Your agents</MicroLabel>
            <p className="text-sm mt-1" style={{ color: 'var(--color-text-secondary)' }}>
              Start a new interaction. It runs with the instructions, tools and MCP servers saved on the agent.
            </p>
          </div>
        </div>
        {list}
      </Card>
    );
  }

  return (
    <div ref={rootRef} className="relative">
      <Button variant="primary" size="sm" testId="new-interaction" onClick={() => setOpen((value) => !value)}>
        {label}
      </Button>
      {open && (
        // A popover under the button from md up; on a phone, where the
        // button may sit anywhere in a wrapped toolbar, a sheet across the
        // bottom of the screen instead.
        <div
          className="z-50 p-3 rounded-xl max-md:fixed max-md:inset-x-0 max-md:bottom-0 max-md:rounded-b-none max-md:max-h-[80vh] max-md:overflow-y-auto md:absolute md:right-0 md:mt-2 md:z-20 md:w-[360px]"
          data-testid="new-interaction-popover"
          style={{ background: 'var(--color-card)', border: '1px solid var(--color-border)', boxShadow: '0 8px 24px rgba(0,0,0,0.12)' }}
        >
          <MicroLabel style={{ display: 'block', marginBottom: 8 }}>Start a conversation with</MicroLabel>
          {list}
        </div>
      )}
    </div>
  );
}
