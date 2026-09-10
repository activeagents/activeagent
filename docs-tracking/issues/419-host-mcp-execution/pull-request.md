# Pull request: execute host MCP tools in dashboard runs and evaluations

Closes [#419](https://github.com/activeagents/activeagent/issues/419).

Published PR: [#421 — Execute host MCP tools in dashboard runs and evaluations](https://github.com/activeagents/activeagent/pull/421).

Previously, a dashboard agent declaring only host tools could send the model
an empty tool roster and record an invented healthcheck as a successful run.
The engine now resolves every declared tool before generation, obtains MCP
schemas from enabled servers, and routes their calls through the same session.
An unbound declaration produces an actionable failed run.

Observed agents can execute and run scenario suites under the existing
execution, ownership, and quota gates. Tool failures remain visible in events,
traces, and evaluation evidence. Native replay requires no host adapter.

## Review notes

- MCP bindings take precedence over the toolbox, with no fallback on an MCP error.
- Discovery never broadens the selected tool roster or enables a catalog server.
- Runtime tool callbacks avoid defining arbitrary host tool names as agent methods.
- Exact MCP names also take precedence over matching builder category names.
- Playwright keeps its singleton and default URL while sharing the generic transport.
- No frontend, deployment, Terraform, or dependency changes.

## Validation

- Full engine suite plus released SolidAgent integration: 318 tests,
  1,441 assertions, no failures/errors/skips (Ruby 4.0.2, Rails 8.1.3.1).
- Repository-wide RuboCop: 516 files, no offenses.
- `git diff --check` passed.
- Native Anthropic replay over simulated HTTP verifies the offered live
  schema, actual MCP call, persisted trace, and saved scenario result.

Local implementation review completed with no remaining blocking findings.
GitHub CI is tracked on the PR; no merge or deployment was requested.
