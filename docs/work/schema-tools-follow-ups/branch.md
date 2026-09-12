# Schema tools follow-ups — branches

One batch of work on 2026-09-12, each item on its own branch and pull request, all
against `main` after the 1.5.2 release (#442) was merged back.

| Branch | PR | Base | Scope |
|---|---|---|---|
| `claude/zealous-turing-4afxvn` | #443 | main | Carry the caller into agent runs (the actor seam); lint fixed, merged with main twice for the changelog |
| `fix/model-spec-provider-round-trip` | #444 | main | A persisted model selection re-runs under its recorded provider |
| `feat/evals-ungrounded-answer` | #445 | main | `ungrounded_answer` fault; wrong tool no longer credited; judge reads more notes (#433) |
| `feat/schema-tools-generator` | #446 | main | `rails g active_agent:schema_tools` and the first SchemaTools docs (#440) |
| `feat/schema-tools-registry` | #447 | main | `SchemaTools.define`, a registry per model, discovery reads it (#441) |
| `feat/delegation-actor` | #448 | #443 | A delegated run inherits its parent's caller |
| `feat/mcp-schema-tools` | #449 | #443 | The MCP facade serves the host's schema tools directly (#439) |

The two stacked on #443 retarget to `main` once it merges.

## Running the suite locally

- `gemfiles/*.lock` are git-ignored, so each checkout resolves its own bundle. A stale local
  lock pinned `solid_agent 0.1.1` on one machine; CI resolves 0.2.0. Under 0.1.1 the workbench
  test `a run pinned to a conversation persists one user turn…` fails on `main` too — it needs
  0.2.0's provenance stamping — so it is not a regression of anything here.
- `bin/test` reads `.env.test`; with no keys present every OpenAI-backed test errors at client
  init. Placeholder keys (`OPENAI_API_KEY=test-…`, and the Anthropic/OpenRouter equivalents)
  let VCR cassettes replay. Run with `CI=1` so VCR refuses to hit the network.
- The RubyLLM provider tests and a handful of Anthropic integration tests are live-network
  and fail without real keys; CI has them. Two of the CI failures seen today were
  `ServiceUnavailable: Connection error` on those, re-run green.
- A stale `test/dummy/config/master.key` that cannot decrypt the tracked credentials fails the
  dummy app's boot with `MessageEncryptor::InvalidMessage`; move it aside.
