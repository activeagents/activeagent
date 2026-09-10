The dashboard can already **describe** a host's MCP tools but cannot **call** them, so an evaluation of any agent whose tools come from the host scores near zero and the model answers without them. Closing that gap in the engine also removes the reason a host would write its own evaluation runner.

Supersedes / narrows https://github.com/activeagents/activeagent/issues/418, which asked for a host-registered executor callback. Reading the code, a callback is the wrong shape: the engine already models everything needed.

### What already exists

- `Agent#mcp_servers` — persisted, and the builder writes it
- `EvaluationToolResolver#configured_entries` — normalises the three stored shapes (bare names, builder hashes, legacy name-keyed Hash)
- `ToolDiscovery#configured_mcp_servers` — enumerates a server's tools
- `ActionAgent.mcp_catalog` — host-registered servers with `transport`, `url`, `tool_hints`
- `PlaywrightMCPClient` — a working Streamable-HTTP MCP client: `initialize` handshake, session id, `call_tool(name, arguments)`

### The gap

`AgentExecutionService#execute_tool` ends at:

```ruby
else
  AgentToolbox.call(name, **kwargs)
end
```

`mcp_servers` is read for discovery and reporting but never consulted at execution. So a tool the dashboard correctly attributes to a host server is dispatched to the engine's built-in toolbox, which does not have it.

### Consequence, measured

In a Rails host (Sparkle) whose agent declares 14 MCP tools:

```ruby
agent.tools & ActionAgent::Agent::AVAILABLE_TOOLS  # => []
```

A scenario asking the agent to run a healthcheck **completed successfully** with `tool_calls: []` and this answer:

> "Running healthcheck… Database connection: Healthy, Cache: Healthy, Search service: Healthy…"

Nothing touched the host. A confidently fabricated answer is worse than an error, and it scores as `expected_tool_not_called`, which reads as an agent-configuration problem rather than an engine limitation.

### Proposal

**1. Dispatch to the agent's MCP servers before falling back to the toolbox.** Generalise `PlaywrightMCPClient` into an MCP client keyed by server url/transport (the Playwright client becomes one configured instance), resolve `name` against the agent's `mcp_servers` via the existing resolver, and call it. Fall back to `AgentToolbox` only when no server claims the tool.

**2. Fail loudly when a declared tool resolves to nothing.** Independent of (1): if an agent declares tools that bind to neither an MCP server nor the toolbox, the run should error rather than let the model answer without them. This alone converts the fabricated healthcheck into an actionable failure.

**3. Drop the observed-agent execution ban once (1) lands.** `Agent#ensure_executable!` refuses `status: :observed`. Its purpose was that an observed agent has nothing to execute — but with host MCP binding, an agent reconstructed from telemetry has exactly what it needs: instructions, model, and declared servers. Evaluating the agent that actually ran in production is the most useful case, and today it is the one that is forbidden.

### Why this matters beyond one host

Without it, every host that wants to evaluate its own agents writes a private runner and threads it into the engine. We are doing that today through `scenario_evaluation_adapter_resolver`, which means customer-specific evaluation code living in a customer's application. With (1)–(3), a host declares `mcp_servers` on an agent and the dashboard runs the catalog itself.

It also makes a **feature matrix** a framework feature rather than a per-host one: one catalog, N agents, pass rate and average tokens per question group. The data is already persisted on `EvaluationScenarioResult` (`status`, `input_tokens`, `output_tokens`, `cost`) joined to the scenario's `group`; only the reporting view is missing.

### Interaction with the open PRs

- **#414** (`codex/evaluation-contract-fixes`) — adds `scenario_evaluation_adapter_resolver`, the host-runtime hook. That hook is what makes host tools reachable *today*, and this proposal is the native replacement for it. Worth landing #414 first and treating the resolver as the compatibility path, not the destination.
- **#405** (conversation workbench) — touches `AgentExecutionService` heavily, including `execute_tool` and tool-row persistence, and adds the `render_ui` tool through the same dispatch. Whichever lands second will need to rebase onto the other's `execute_tool`; worth sequencing deliberately rather than in parallel.
- **#415** (dashboard assistant) — reads recorded evaluation results as evidence. Unaffected by the dispatch change, and a beneficiary of the matrix data.
