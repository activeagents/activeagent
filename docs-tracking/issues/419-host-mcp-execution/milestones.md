# Issue 419 milestones

- [x] Confirm the issue requirements, current main, and related open PRs.
- [x] Extract a reusable MCP client while retaining the Playwright interface.
- [x] Reuse configured-server normalization and bind only enabled servers.
- [x] Offer live schemas and dispatch selected host tools before built-ins.
- [x] Fail unresolved declarations before provider generation.
- [x] Enable observed agent execution and evaluation through existing gates.
- [x] Exercise a native provider/MCP replay and persist its evaluation evidence.
- [x] Cover tool errors, session handling, config shapes, namespaces, and collisions.
- [x] Complete final engine, integration, and lint validation.
- [x] Publish the branch and open [PR #421](https://github.com/activeagents/activeagent/pull/421).

## Scope decisions

The observed-agent prohibition exists in API controllers on current main,
not `Agent#ensure_executable!` as described in the issue. Only those execution
prohibitions are removed. Ownership, execution switch, and quota checks remain.

The feature-matrix reporting view mentioned as a future benefit in the issue
is outside its three implementation proposals. Existing scenario results
continue to store tool calls, tokens, cost, and faults.

The generic transport supports HTTP/HTTPS Streamable HTTP, including JSON/SSE
responses and stateless sessions. It does not launch stdio servers or implement
OAuth/custom authentication headers. Hosts must provide a reachable endpoint
compatible with this transport.

Protocol references used during implementation:
- [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports)
- [MCP lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle)

Test logs are kept in the gitignored `tmp/issue-419/` directory.

## Validation

Ruby 4.0.2, Rails 8.1.3.1, and released SolidAgent 0.2.0:

```sh
BUNDLE_GEMFILE=gemfiles/rails8.gemfile VCR_RECORD_MODE=none bin/test \
  actionagent/test/*_test.rb test/integration/solid_agent/*_test.rb
```

318 tests, 1,441 assertions, zero failures, errors, or skips. MCP and provider
requests are simulated; no host tools or paid model APIs were called.

Repository-wide RuboCop: 516 files inspected, no offenses. `git diff --check`
also passed. GitHub CI remains a separate check on the published branch.
