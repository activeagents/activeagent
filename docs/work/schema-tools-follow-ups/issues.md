# Schema tools follow-ups — issues

## The list this batch set out to close

| Item | Outcome |
|---|---|
| #443 caller carried into agent runs | Lint fixed (a blank line main had already removed), merged with main, changelog merged. Merges once CI is green. |
| #442 release 1.5.2 back to main | Merged. `main` says 1.5.2 for both gems. |
| #439 schema tools served over MCP | `Api::MCPController` lists every discovered schema tool with its own parameter schema and dispatches `tools/call` to `SchemaTools.call(name, actor: agent_actor)`. `ActionAgent.mcp_schema_tools = false` keeps them behind agents. |
| #440 generator | `rails g active_agent:schema_tools Model`: every column listed, commented out, with its type; secrets left off; `scope_by_policy` when the policy exists. |
| #441 runtime definitions and the descendants leak | `SchemaTools.define` registers one class per model; discovery reads runtime classes from the registry, never from `descendants`. Persistence of the declaration stays the host's. |
| #433 judge cannot detect fabrication | `ungrounded_answer` fault for a scenario with no tool expectation; `expected_tool_not_called` carries `ungrounded: true` and names the claim; `tools_succeeded` no longer credits a wrong tool; the judge reads 1,500 characters of notes. Where the scenario declares `tools:`, `main` already raised a fault — that half of the issue was stale. |

## Found on the way

| Finding | Where it went |
|---|---|
| `ModelSpec.parse_all` re-parsed a persisted spec from its label, so an OpenRouter `anthropic/…` model became Anthropic's once that SDK was installed | #444 |
| `Delegation::Runner` built the sub-agent without the parent's caller, so a delegated run was unattributed | #448 |
| `ActiveAgent::NotAuthorized` is defined in `concerns/authorization.rb`, loaded only with `Base`; the engine referencing it before any agent class loaded raised `NameError` | `autoload :NotAuthorized` in `lib/active_agent.rb`, in #449 |
| `McpAuthorizationTest`'s refusal case fails when run after `AgentAuthorizationTest` (order-dependent); passes alone and in CI | Not fixed; noted for #443 |
| `Docs::AgentsExamplesTest::QuickExampleTest` failed once on CI with `ActionNotFound: list_evaluations` for its `SupportAgent` — a constant shared with the dashboard assistant tests, order-dependent | Re-run green; not fixed |

## Not done

- Persisting schema-tool declarations (a table, a dashboard form) — the registry is the seam.
- The judge-limit accounting from #433's "adjacent limits".
- #441's option 3, an instance-based definition with no classes.
