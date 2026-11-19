# Schema tools presence filter — branch

| Branch | PR | Base | Scope |
|---|---|---|---|
| `feat/schema-tools-presence-filter` | #718 | `main` (after 1.9.8) | `{"present": true\|false}` on SchemaTools filters |

Files: `lib/active_agent/schema_tools.rb`, `test/schema_tools_test.rb`,
`docs/actions/tools.md`, `CHANGELOG.md` (`[Unreleased]`).

Local runs follow `docs/work/schema-tools-follow-ups/branch.md` ("Running the suite locally"):
a placeholder `.env.test`, `CI=1`, and the live-network RubyLLM/Anthropic tests failing without
real keys.
