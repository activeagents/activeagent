# v2 extraction roadmap — what the platform taught us belongs in the framework

The ActiveAgents platform (activeagents/activeagents) has been the field lab
for the gems: every gap in `activeagent` or `solid_agent` shows up there as
app-level code. This document is the audit of that code, drawing the line for
the three-layer architecture:

- **activeagent** — execution: agents, providers, tools, telemetry
- **solid_agent** — persistence: contexts, generations, tool streams, memory,
  pricing
- **the platform** — accounts, billing, quotas, hosted UI, multi-tenancy

The solid_agent side of this audit already landed (enriched tool persistence,
`ModelPricing`, memory/tool-cache contracts). What follows is the
framework-shaped remainder, proposed for v2 — each item exists today as
platform code that any serious consumer of the gem would have to rebuild.

## Absorb from the platform

### 1. Per-model capability gating
The platform strips `temperature`/`top_p` for models that reject them
(Claude Opus 4.7+, Sonnet 5, Fable/Mythos 5) via a regex before
`generate_with`. The framework has no capability layer at all — the request
objects apply `DEFAULTS` (`temperature: 1, top_p: 1`) unconditionally and let
the vendor 400. v2: a model-capability table consulted by the Request layer
(sampling params, max_tokens vs max_completion_tokens, reasoning-effort
support), with a config escape hatch for unknown models.

### 2. Provider model catalogs
The platform's `/api/provider_models` queries Ollama's live model list, the
Anthropic Models API, and OpenRouter's catalog, with curated fallbacks.
v2: `Provider#models` on the provider contract (vendor SDKs all expose a
listing endpoint), so model pickers and validation stop being app problems.

### 3. Tool-loop safety
`process_prompt_finished` re-enters `resolve_prompt` with **no max-turn cap
and no token/cost budget** — a looping model recurses until the provider
stops emitting tool calls. v2: `max_tool_turns` and a token budget on the
generation, with a clean partial-result return when hit.

### 4. Agent-to-agent delegation
`tools_function` only routes back to `self`. The platform built `call_agent`
(sub-agent invocation with a `Thread.current` depth cap) as an app tool.
v2: a first-class delegation primitive — invoke another agent class/instance
as a tool, with depth limits and shared trace/context correlation.

### 5. Provider error taxonomy + fallback
Only `ProvidersError` exists and nothing raises it; rate limits, context
overflows, and content filters surface as vendor-specific exceptions, so no
retry/fallback policy can be written against them. v2: typed errors
(`RateLimited`, `ContextLengthExceeded`, `ContentFiltered`, …) normalized
across providers, then a `generate_with ... fallback: [:anthropic, :ollama]`
chain becomes expressible.

### 6. A real MCP story
Today MCP is pass-through only: `mcps:` options are normalized into each
vendor's *remote* MCP format (the LLM vendor's servers do the connecting).
There is no MCP client (stdio/HTTP, `tools/list` discovery → routable
actions) and no server facade. The platform built an MCP server over its
agents (`run_<slug>` tools, `agent://` resources, Bearer auth) as a
controller. v2: both halves — a client that turns any MCP server's tools
into agent actions, and a mountable engine that presents agents as an MCP
server.

### 7. Tool DSL / schema derivation
`lib/active_agent.rb`'s docstring advertises a `tool def get_weather(...)`
macro that does not exist; tools are hand-written JSON Schema hashes.
solid_agent's `HasTools` (DSL + JSON view templates) already fills this —
v2 should either absorb it or bless it as the canonical declaration path,
not leave two half-standards.

### 8. Server-side tool implementations
The platform's `AgentToolbox` (safe `fetch_url` with SSRF guard + redirect
caps, `web_search`, a no-eval `Calculator`, allowlisted `browse_page`) is
generic execution code with zero app coupling. It belongs beside the
framework's tool routing, not in a dashboard app — persistence/caching of
results stays solid_agent's.

## Fix in place (bugs and dead seams found during the audit)

- `telemetry/instrumentation.rb` calls `self.class.generation_provider`
  (method doesn't exist → `llm.provider` attribute always "unknown"/absent),
  registers `around_generate` (macro is `around_generation` → permanently
  dead line), and guards on `respond_to?(:messages)` (Base has no
  `#messages` → message counts never recorded).
- `Observers`/`Interceptors` call `Prompt.register_observer` on an
  `ActiveAgent::Prompt` class that doesn't exist; nothing in the generation
  path notifies them. Either implement the ActionMailer-style seam
  (persistence layers want it) or delete it.
- Telemetry `capture_bodies`/`redact_attributes` are documented config that
  is never consumed, while notification payloads attach full raw responses.
  Implement redaction before v2 ships.
- The dashboard engine ships orphaned platform-shaped models
  (`Dashboard::Agent`, `AgentRun`, `SandboxSession`, jobs, migrations) with
  no controllers or routes. Decide: wire them (framework-level run
  orchestration — run records, status, cancellation would pair with the
  tool-loop limits above) or drop them from the gem.

## Stays in the platform

Accounts/users, billing and plan quotas, encrypted API/provider key storage,
trace retention by plan, the hosted React dashboard, sandboxes/session
recordings, and the account-scoped `TelemetryTrace` subclass. These touch
tenancy and money; the gems should expose seams (auth hooks, quota
callbacks), never implementations.

## solid_agent follow-ups (tracked there, listed for completeness)

- `agent_runs` + persisted run progress events (the platform's
  `AgentRun#append_event` and instruction-cohort fingerprints are the
  proven shape).
- Evaluation datasets — `docs/agent-md-spec.md` already specifies
  `*.test.yml` cases; the platform's rule-criteria scorer and LLM-judge
  plumbing are the reference implementation.
- Fold the platform's drifted model copies back onto the generator
  templates once the app's Gemfile.lock reaches solid_agent 0.2.
