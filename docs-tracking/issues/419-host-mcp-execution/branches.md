# Branch: host MCP execution

- Issue: [activeagents/activeagent#419](https://github.com/activeagents/activeagent/issues/419)
- Branch: `codex/419-host-mcp-execution`
- Base: `main` at `1ab417d721b1d636144d0e83f38a4f0f48943dd6`
- Repository: `activeagents/activeagent` (the engine/framework repository).
- Working checkout: isolated from the user's `activeagents` application checkout.

## Related work

- [#414](https://github.com/activeagents/activeagent/pull/414) remains open:
  its host evaluation adapter can remain a compatibility path. This change
  implements native MCP replay on current `main` and does not depend on that PR.
- [#405](https://github.com/activeagents/activeagent/pull/405) remains open:
  both changes touch `AgentExecutionService`. Preserve its conversation and
  `render_ui` behavior when rebasing; dispatch selected MCP bindings before
  built-ins, and keep tool calls flowing through the service's allowlist.
- [#415](https://github.com/activeagents/activeagent/pull/415) consumes saved
  evaluation evidence and needs no integration change here.
