import React, { useState } from 'react';

// The tools an agent carried into a generation, as clickable chips instead
// of a raw schema dump. Clicking a chip opens the tool's definition:
// description, parameters, and where the tool comes from (MCP server, gem,
// or a method defined on the agent class).

// Telemetry doesn't yet tag every tool with an origin, so derive what we
// can: explicit fields first, then the mcp__server__tool naming convention,
// else it's a method the agent itself defines.
export const toolSource = (tool) => {
  const server = tool.mcp_server || tool.server;
  if (server) return `MCP server · ${server}`;
  if (typeof tool.name === 'string' && tool.name.startsWith('mcp__')) {
    return `MCP server · ${tool.name.split('__')[1]}`;
  }
  if (tool.gem) return `gem · ${tool.gem}`;
  if (tool.source) return String(tool.source);
  return 'agent-defined · method on the agent class';
};

const toolParams = (tool) => {
  if (Array.isArray(tool.parameters)) return tool.parameters;
  if (tool.parameters && typeof tool.parameters === 'object') {
    return Object.keys(tool.parameters.properties || tool.parameters);
  }
  return [];
};

export function ToolDetails({ tool, darkMode }) {
  const params = toolParams(tool);
  return (
    <div style={{ display: 'grid', gap: '4px' }}>
      {tool.description && (
        <div className="text-sm" style={{ color: darkMode ? 'rgba(255,255,255,0.75)' : '#4b5563' }}>
          {tool.description}
        </div>
      )}
      <div
        className="text-xs font-mono"
        style={{
          color: darkMode ? 'rgba(255,255,255,0.45)' : '#9ca3af',
          display: 'flex',
          flexWrap: 'wrap',
          columnGap: '16px',
          rowGap: '4px',
        }}
      >
        <span>params: {params.length > 0 ? params.join(', ') : 'none'}</span>
        <span>source: {toolSource(tool)}</span>
      </div>
    </div>
  );
}

export default function ToolRoster({ tools, darkMode }) {
  const [openName, setOpenName] = useState(null);
  const list = (tools || []).filter((tool) => tool && tool.name);
  if (list.length === 0) return null;

  const openTool = list.find((tool) => tool.name === openName);
  const chipStyle = (active) => ({
    background: darkMode ? 'rgba(34,197,94,0.12)' : '#f0fdf4',
    color: darkMode ? '#86efac' : '#15803d',
    border: `1px solid ${active ? (darkMode ? '#4ade80' : '#22c55e') : 'transparent'}`,
    borderRadius: '6px',
    padding: '2px 8px',
    fontSize: '11px',
    cursor: 'pointer',
  });

  return (
    <div style={{ marginTop: '8px' }}>
      <div className="flex items-center gap-1.5 flex-wrap font-mono">
        <span
          className="text-xs uppercase"
          style={{ letterSpacing: '0.05em', color: darkMode ? 'rgba(255,255,255,0.45)' : '#9ca3af' }}
        >
          tools
        </span>
        {list.map((tool) => (
          <button
            key={tool.name}
            onClick={(e) => {
              e.stopPropagation();
              setOpenName(openName === tool.name ? null : tool.name);
            }}
            title={openName === tool.name ? 'Hide definition' : 'Show definition'}
            style={chipStyle(openName === tool.name)}
          >
            ⚙ {tool.name}
          </button>
        ))}
      </div>
      {openTool && (
        <div
          onClick={(e) => e.stopPropagation()}
          style={{
            marginTop: '6px',
            padding: '8px 10px',
            borderRadius: '8px',
            background: darkMode ? 'rgba(34,197,94,0.06)' : '#f7fef9',
            border: `1px solid ${darkMode ? 'rgba(34,197,94,0.25)' : '#bbf7d0'}`,
          }}
        >
          <ToolDetails tool={openTool} darkMode={darkMode} />
        </div>
      )}
    </div>
  );
}
