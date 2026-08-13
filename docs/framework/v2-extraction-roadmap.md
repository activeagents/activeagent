# v2 extraction roadmap — what the platform taught us belongs in the framework

The ActiveAgents platform (activeagents/activeagents) has been the field lab
for the gems: every gap in `activeagent` or `solid_agent` shows up there as
app-level code. This document is the audit of that code, drawing the line for
the three-layer architecture:

- **activeagent** — execution: agents, providers, tools, telemetry
- **solid_agent** — persistence: contexts, generations, tool streams, memory,
  pricing
- **the platform** — accounts, billing, quotas, multi-tenancy

The solid_agent side of this audit already landed (enriched tool persistence,
`ModelPricing`, memory/tool-cache contracts). What follows is the
framework-shaped remainder, proposed for v2 — each item began as platform
code that any serious consumer of the gem would have to rebuild.

## Absorb from the platform

### 1. Per-model capability gating — ✅ shipped
`ActiveAgent::ModelCapabilities` strips parameters the target model rejects
(temperature/top_p on thinking-first Claude, OpenAI o-series/GPT-5) from
prepared prompt parameters before they reach the provider. Extensible via
`ModelCapabilities.register(pattern, unsupported:)`; disable with
`ModelCapabilities.enabled = false`. Remaining for v2: max_tokens vs
max_completion_tokens switching and reasoning-effort awareness.

### 2. Provider model catalogs
The dashboard engine's `<mount>/api/provider_models` queries Ollama's live
model list, the Anthropic Models API, and OpenRouter's catalog, with curated
fallbacks — still a dashboard endpoint rather than a provider capability.
v2: `Provider#models` on the provider contract (vendor SDKs all expose a
listing endpoint), so model pickers and validation stop being app problems.

### 3. Tool-loop safety — ✅ shipped (turns)
`max_tool_turns` (default 25, per agent/prompt override) now bounds the
tool-calling recursion; hitting the cap emits
`tool_turns_exceeded.active_agent` and returns the messages gathered so far.
Remaining for v2: a token/cost budget alongside the turn cap.

### 4. Agent-to-agent delegation
`tools_function` only routes back to `self`. The platform built `call_agent`
(sub-agent invocation with a `Thread.current` depth cap) as an app tool.
v2: a first-class delegation primitive — invoke another agent class/instance
as a tool, with depth limits and shared trace/context correlation.

### 5. Provider error taxonomy + fallback — ✅ taxonomy shipped
`ActiveAgent::Providers::Errors` (RateLimited, ContextLengthExceeded,
AuthenticationFailed, ContentFiltered, ServiceUnavailable, InvalidRequest)
now normalizes vendor exceptions in `with_exception_handling` — classified
by SDK class name, HTTP status, and message heuristics, original preserved
as `#cause` — so `rescue_from` policy is portable across providers.
Remaining for v2: the `generate_with ... fallback: [:anthropic, :ollama]`
chain the taxonomy makes expressible.

### 6. A real MCP story — ✅ server half shipped
The server facade landed with the dashboard engine: an owner's agents are
presented as an MCP server at `<mount>/mcp` (`run_<slug>` tools,
`agent://` resources, Bearer API-key auth) over Streamable HTTP JSON-RPC.
On the client side MCP is still pass-through only: `mcps:` options are
normalized into each vendor's *remote* MCP format (the LLM vendor's servers
do the connecting), and the one client in the gem
(`Dashboard::PlaywrightMcpClient`) speaks just enough JSON-RPC for one
server. Remaining for v2: a general MCP client (stdio/HTTP, `tools/list`
discovery → routable actions) that turns any MCP server's tools into agent
actions.

### 7. Tool DSL / schema derivation
`lib/active_agent.rb`'s docstring advertises a `tool def get_weather(...)`
macro that does not exist; tools are hand-written JSON Schema hashes.
solid_agent's `HasTools` (DSL + JSON view templates) already fills this —
v2 should either absorb it or bless it as the canonical declaration path,
not leave two half-standards.

### 8. Server-side tool implementations — ✅ in the gem, wrong layer
`AgentToolbox` (safe `fetch_url` with SSRF guard + redirect caps,
`web_search`, a no-eval `Calculator`, allowlisted `browse_page`) now ships
in the gem as `ActiveAgent::Dashboard::AgentToolbox`. It is generic
execution code with zero app coupling, so v2 should move it beside the
framework's tool routing rather than leave it reachable only through the
dashboard engine — persistence/caching of results stays solid_agent's.

## Fix in place (bugs and dead seams found during the audit)

- ✅ **Fixed**: `telemetry/instrumentation.rb` — provider/model/message-count
  attributes now record (was: nonexistent `generation_provider`, private
  helpers hidden from `respond_to?`, nonexistent `Base#messages`); the dead
  `around_generate` registration is removed.
- ✅ **Fixed**: `redact_attributes` is now consumed — span and span-event
  attribute values matching the configured patterns become `[REDACTED]` in
  `build_trace_payload`, covering both transmission and local storage.
  `capture_bodies` remains reserved (telemetry spans capture no bodies yet;
  the raw response on the ActiveSupport::Notifications payload is
  in-process only).
- `Observers`/`Interceptors` call `Prompt.register_observer` on an
  `ActiveAgent::Prompt` class that doesn't exist; nothing in the generation
  path notifies them. Either implement the ActionMailer-style seam
  (persistence layers want it) or delete it.
- ✅ **Fixed**: the dashboard engine's platform-shaped models
  (`Dashboard::Agent`, `AgentRun`, `SandboxSession`, jobs, migrations) are
  wired — the engine now ships the controllers, routes and React UI that
  drive them, and the install generator creates their tables in a second
  migration (skippable with `--traces_only`).

## Stays in the platform

Accounts/users, billing and plan quotas, which retention window applies to
which plan, the managed sandbox infrastructure the engine's backends talk
to, and the account-scoped `TelemetryTrace` subclass. These touch tenancy
and money; the gems should expose seams (auth hooks, quota callbacks),
never implementations. The dashboard UI, key storage, sandbox and session
recording code that used to sit here now ships in the engine, configured
per host.

## solid_agent follow-ups (tracked there, listed for completeness)

- ✅ **Shipped**: `agent_runs` + persisted run progress events — the install
  generator now ships an `AgentRun` model with lifecycle, `append_event`,
  trace correlation, and `SolidAgent::RunFingerprint` instruction cohorts.
- Evaluation datasets — `docs/agent-md-spec.md` already specifies
  `*.test.yml` cases; the platform's rule-criteria scorer and LLM-judge
  plumbing are the reference implementation.
- Fold the platform's drifted model copies back onto the generator
  templates once the app's Gemfile.lock reaches solid_agent 0.2.
