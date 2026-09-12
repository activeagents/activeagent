# Schema tools follow-ups — pull requests

Each PR carries its own description and testing section; this is the map.

- **#443** — the caller seam. Not authored in this batch; brought to green (lint) and kept
  merged with main. Everything actor-related below builds on it.
- **#444** — `ModelSpec` keeps a persisted spec's provider. 137 evals/engine tests green. Merged.
- **#445** — `ungrounded_answer`, `expected_tool_not_called` names the fabrication,
  `tools_succeeded` only for an expected tool, judge reads 1,500 characters of notes.
  156 tests green.
- **#446** — `active_agent:schema_tools` generator; SchemaTools documented in
  `docs/actions/tools.md`. 65 tests green.
- **#447** — `SchemaTools.define` / registry / discovery. 59 tests green; full suite green
  apart from the live-network RubyLLM tests.
- **#448** — delegation inherits the caller. 12 tests green. Stacked on #443.
- **#449** — schema tools over the MCP facade, `ActionAgent.mcp_schema_tools`,
  `autoload :NotAuthorized`, and this work record. 30 MCP/authorization tests green.
  Stacked on #443.

Merge order: #443, then the three independent PRs as CI clears them (each takes a merge
from main for the changelog), then #448 and #449 retargeted to main.
