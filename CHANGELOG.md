# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Hand a browser run to a person** (`actionagent`). Agents with the
  `playwright_mcp` tools gain `request_handoff`: the agent calls it when a
  page asks for something only its owner may give (payment details, a login
  code), the run's session recording stores the page URL and the non-secret
  values already entered, and Session Replay's **Take Over Session** opens
  that page for the person. Browser tool calls in such runs are recorded, so
  the run plays back in Session Replay.
- **Conference Ticket Agent template** (`actionagent`). Registers on an
  event's ticket page and stops before paying, built for the SF Ruby
  Conference demo. The Playwright demo template now names the published
  `@playwright/mcp` package.
- **Conference-ticket sample data** (`actionagent`). `bin/rails
  action_agent:sample:conference_ticket` seeds a workspace with fictional
  but complete data for the scenario: the agent, a week of runs with their
  telemetry traces (browser tool spans, model calls, the handoff), a
  completed session recording that offers Take Over at the ticket page, and
  an evaluation whose two runs show a caught regression — the agent once
  clicked Pay — and the fix. Every record carries a `sample` marker;
  `action_agent:sample:clear` removes it all. `ACCOUNT_ID` names the
  workspace on a multi-tenant install.
- **Typing and forms in the browser tools** (`actionagent`). The
  `playwright_mcp` tools gain `browser_type`, `browser_fill_form`,
  `browser_select_option` and `browser_press_key`, and address elements the
  way current Playwright MCP releases expect (`target`), accepting the `ref`
  the schemas ask the model for.
- **Support MCP across providers** (`activeagent`). Anthropic and OpenAI
  Responses handle remote servers natively; ActiveAgent bridges other providers
  and all local `command:` servers. `mcp_strategy:` selects automatic, client,
  or required-native execution. Tool lists are cached for five minutes; a cold
  cache connects during discovery, while a warm cache connects only when a tool
  is called. `mcp_cache: false` bypasses the cache for one generation. Entries
  are scoped by endpoint, credentials, environment, and `allowed_tools:`. The
  client-side bridge requires the optional `mcp` gem.
- **Add a DeepSeek provider** (`activeagent`). `generate_with :deepseek` uses
  DeepSeek's OpenAI-compatible API, `deepseek-flash` by default, and
  `DEEPSEEK_API_KEY` as the credential fallback. JSON output and tool calling
  are native. Instructions are sent as `system` messages, and provider defaults
  such as thinking mode are left unchanged. Thinking is billed and disables
  sampling parameters; prompts can opt out with `thinking: { type: "disabled" }`.
- **Ship dashboard migrations as numbered templates** (`actionagent`).
  `rails g action_agent:install` also emits every
  `templates/migrations/NNN_<name>.rb.erb` in the generator, in number order and
  after the other dashboard migrations, skipping any whose name `db/migrate`
  already holds. A new engine migration is one new template file.
- **Ask the host before privileged dashboard actions** (`actionagent`).
  `ActionAgent.permission_checker = ->(user, action, subject) { ... }` is asked
  before a provider credential is stored, tested or deleted
  (`:manage_credentials`), before GitHub is connected, its repositories chosen
  or it is disconnected (`:manage_github`), and before an API key is created or
  revoked (`:manage_api_keys`). A denial answers 403, except that the GitHub
  connect and callback navigations return to Settings instead. The remaining
  actions in `ActionAgent::PERMISSION_ACTIONS` are reserved for features that
  need them. Unset, every action is allowed as before, which in multi-tenant
  mode means every member of a tenant may perform every action; the engine
  logs a warning at boot in that case. A checker that raises denies; in
  multi-tenant mode a nil answer or a missing user also denies.
- **Record who created an API key** (`actionagent`). A key created in Settings
  stores the signed-in user beside its owner, and an MCP call made with an
  account's key runs as that user. Keys created earlier have no creator and
  behave as before.
- **Organization and personal provider keys** (`actionagent`). A provider
  key is an organization key, shared by the account's members, or a member's
  personal key. With `ActionAgent.provider_key_scope = :personal_override`, a
  member saves personal keys in Settings → API Keys, and the runs they start,
  the dashboard assistant and the model pickers use them before the
  organization's; the judge, sandboxes, Claude Code and Codex use organization
  keys only, as do scenario replays on a multi-tenant install, so the
  evaluation form offers only the providers those keys cover. A personal
  Ollama host decides where the server sends requests, so saving or testing
  one asks `permission_checker` for `:manage_credentials`, with the personal
  key as the subject, as an organization key does. Every lookup goes through
  `ActionAgent::ProviderCredentials.resolve(owner:, actor:, provider:)`: the
  actor's personal key, then `provider_credentials_resolver`, then the
  organization key, then `config/active_agent.yml`. A resolver that declares
  `actor:` is told who is acting. With `multi_tenant` on, an owner that does
  not resolve to the configured owner class, or a resolver that raises, fails
  the generation with `ProviderCredentials::Unresolved` instead of using the
  platform's credentials. The provider keys API takes `scope=organization` or
  `scope=personal` and returns `scope`, `effective_source`, `set_by` and
  `updated_at`, and `POST /api/provider_keys/test` sends a stored key only to
  the stored host. The Organization page manages the
  organization's keys and lists the members `ActionAgent.members_resolver`
  returns, with "+ Invite Member" linking to `ActionAgent.member_invite_url`
  (`GET /api/members`). **Upgrading:** run the new `add_provider_key_scope`
  migration (`rails g action_agent:install` emits it); it stops and lists the
  keys if an account holds two for one provider. A host that keeps its own
  `provider_keys` table with a unique `(account_id, provider)` index replaces
  it with `(account_id, scope_key, provider)`. Before turning on
  `:personal_override`, change any `provider_credentials_resolver` that reads
  `provider_keys` by provider alone so it reads organization rows only
  (`ProviderKey.for_owner`), or remove it.
- **Declare optional sandbox backend verbs** (`actionagent`).
  `SandboxOrchestrator` dispatches `changed_files`, `read_file`,
  `start_browser`, `stop_browser` and `resume_boot` to a backend that defines
  them, and `supports?` is false for one that does not. Their signatures are
  documented on the orchestrator and in the dashboard guide; the `:mock` and
  `:local` backends implement none of them. `read_file` refuses a path outside
  the checkout before the backend sees it.
- **Check out sandboxes through a GitHub App** (`actionagent`). Configure
  `github_app_id`, `github_app_private_key`, `github_app_slug`,
  `github_app_client_id` and `github_app_client_secret` (or the matching
  `GITHUB_APP_*` variables), and Settings -> Integrations offers **Install
  the GitHub App**. An installation is linked only after the App's user
  authorization shows the user is the account it is installed on or an
  active admin of its organization, and that user's token is then dropped.
  An installation belongs to one owner at most. Its repositories are chosen
  like the OAuth connection's, and a checkout of one of them mints a one-hour
  token limited to that repository's contents, once per provision, held in
  memory only. When a repository is reachable both ways, the installation
  is used. The App's JWT is signed with OpenSSL, so there is no new
  dependency. Run `rails g action_agent:install` and `rails db:migrate` for
  the `github_installations` table and
  `sandbox_sessions.github_installation_id`. The OAuth connection works as
  before. Installing, linking, listing and choosing an installation's
  repositories, and unlinking it ask `ActionAgent.permission_checker` for
  `:manage_github`. An installation GitHub reports removed or suspended is
  marked, and **Check again** clears the mark once GitHub serves it again.
- **Create the GitHub App from Settings** (`actionagent`). On a
  single-tenant dashboard, **Create GitHub App** posts a manifest to GitHub
  and shows the new App's credentials once, with the configuration to add.
  The dashboard stores none of them.
- **Mask GitHub tokens in sandbox output by their shape** (`actionagent`).
  `SecretScrubber` masks `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_` and
  `github_pat_` tokens even when it is given no values, so a code session's
  transcript masks a checkout token it never knew.
- **Store browser events on session recordings, and read any session as a
  timeline** (`actionagent`). `POST <mount>/api/session_recordings/:id/events`
  takes a batch of `rrweb`, `console` and `marker` events under the
  `recording_events` key, authenticated by the recording's ingest token
  (`SessionRecording#issue_ingest_token!`, stored as a digest, expiring with
  the recording or its sandbox) or by a dashboard session that owns the
  recording. Each batch's clock offset is applied, so events are stored in
  server time, and an event more than a day before the batch's `sent_at` is
  refused. Batches over `ActionAgent.recording_limits` answer 413 and are
  counted as dropped. The engine adds `recording_events` to the app's
  `filter_parameters`. `GET .../events?after=` reads them back in time order.
  `GET <mount>/api/session_recordings/:id/timeline` and
  `GET <mount>/api/sessions/{context,run,scenario_result}/:id/timeline` return
  message, LLM, tool and browser lanes, derived when read from runs, messages,
  generations and telemetry spans. An agent's browser tool calls are recorded
  as `action` events with typed values masked. A recording can belong to a
  conversation (`agent_context_id`) and records its `source`. Deleting a
  recording asks the permission checker about `:manage_recordings`. Adds
  migration `create_active_agent_recording_events`.
  documented on the orchestrator and in the dashboard guide; the `:mock`
  backend implements none of them. `read_file` refuses a path outside the
  checkout before the backend sees it.
- **Boot a checkout that does not bundle the engine** (`actionagent`). An
  `app_runtime` sandbox of a Rails app whose `Gemfile.lock` locks no
  `actionagent` now installs it first: the dashboard's own engine version (or
  the same git revision or path), the generators with `--skip`, asset builds
  the app defines, `db:prepare`, then the manifest. `POST /api/sandboxes`
  takes `bootstrap` (`auto` by default, `always` or `never`), `start_url` and
  `keep_on_failure`. Before any of a bootstrapped checkout's commands runs, a
  preflight refuses one without a root `config/application.rb`, or locking
  Ruby older than 3.2 or railties older than 7.2. With `"auto"` a checkout
  without a `Gemfile.lock` boots as before, and with `"always"` the preflight
  refuses it. Each step has a log and a timeout of its own (1800 seconds for
  the whole bootstrap, or `local_sandbox_boot_timeout` on `:local` when that
  is longer), and `GET /api/sandboxes/:id/boot` and `…/boot_log` read them
  back, scrubbed.
  With `keep_on_failure`, `POST /api/sandboxes/:id/resume_boot` continues a
  failed boot from the step that failed, on the same checkout and databases.
  Once the MCP facade answers, `start_url` must not answer `5xx`. The boot is
  a plain-JSON spec (`ActionAgent::SandboxBootSpec`) the orchestrator hands a
  backend whose `create_sandbox` takes `boot_config:`; any other backend boots
  as before. The `:local` backend implements `resume_boot`, `boot_status` and
  `boot_log`, and the reaper releases a kept boot once its sandbox expires.
- **Sync a checkout's agents in the sandbox manifest** (`actionagent`).
  `bin/rails action_agent:sandbox:manifest` also mirrors the app's
  `app/agents` classes with `AgentSync`, so a sandbox's MCP facade serves
  their `run_<slug>` tools. The manifest's API key and the synced agents each
  belong to the only record of the class their model is owned through, when
  there is exactly one (the only account for the key and the only user for the
  agents, in an app that configures both), and to nobody in an app with no
  owner model, where `AgentSync` now accepts a nil owner.
- **Create evaluations and merge scenarios over MCP** (`actionagent`). The
  facade's `evaluations_create` tool creates an evaluation of one of the key's
  agents, with scenarios or criteria, and runs nothing. `scenarios_merge` adds
  scenarios to an evaluation and updates the ones whose keys it holds, through
  the new `Evaluation#merge_scenarios!`, which never removes, disables or
  reorders a scenario it was not given. A scenario without a key gets the next
  `<group>_<n>` the evaluation does not use, and `key_prefix` namespaces
  generated keys. Both tools ask the permission checker about
  `:replace_scenarios` as the key's user, refuse an observed agent's suite as
  `evaluations_run` does, and are held to 100 evaluations per agent, 2,000
  scenarios per evaluation, 2 MiB of scenarios per call, and 200-character
  scenario keys, groups and judge models. A refused call writes nothing.
- **Generate scenario keys around keys already in use** (`activeagent`).
  `ScenarioParser.parse` and `.scenarios` take `reserved_keys:`, which
  generated keys skip ignoring case, and `key_prefix:`, a namespace in front
  of every generated key. A prefix with no letters or digits a key can use
  raises `ParseError`. Keys a paste names are unchanged.

### Changed

- **Record an agent's browser tool calls as recording events**
  (`actionagent`). `ActionAgent::MCPRecordingMiddleware#intercept` now stores
  each call to a tool in `MCPRecordingMiddleware::PLAYWRIGHT_TOOLS` as one
  `action` event, with typed values masked and the owner's credentials
  scrubbed, instead of writing `RecordingAction`s through
  `SessionRecordingService`. It no longer extracts screenshots from tool
  results. `AgentExecutionService` wraps every tool call with it, so a run's
  first browser call starts the run's recording (`source: "agent"`). The
  constructor no longer starts a recording: `#recording` and
  `#recording_service` find or start one on first use, and are `nil` when none
  can be started. The Session Replay page reads `/actions`, so it lists these
  recordings with no actions until the replay view moves to the timeline; read
  them from `GET .../timeline` or `GET .../events?kind=action`. The
  `record_navigate`, `record_click`, `record_type` and `capture_for_handoff`
  helpers still write `RecordingAction`s.
- **Announce run and sandbox changes without their content** (`actionagent`).
  The Action Cable messages on `agent_run_<id>`, `agent_runs_<agent_id>` and
  `sandbox_<session_id>` are now `{ type, id, status }`; a subscriber reads
  the run or sandbox back over the JSON API. Nothing is broadcast when the host
  has not loaded Action Cable. A host channel or client that read `run`,
  `sandbox`, `task`, `error` or `provider` from these messages must refetch.
- **Pause a generation to ask the user, and resume it with the answer**
  (`activeagent`). A tool returns an `ActiveAgent::InputRequest` (`:text`,
  `:choice`, `:confirm` or `:secret`); the turn's other calls finish, nothing
  is sent back to the model, and the response is `awaiting_input?` with
  `input_requests` and a JSON-safe `checkpoint`. `Generation#resume_now(checkpoint:,
  answers:)`, on the generation that paused or on one built the same way,
  restores the conversation and dispatches each paused call again with its
  answer readable through `input_answer` / `InputRequest.answer_for`; `false`
  declines without running the tool. A `:secret` answer is scrubbed from tool
  results, telemetry tool spans and tool errors. Pauses publish
  `input_requested.active_agent` and run `on_input_request` callbacks; a
  delegated agent that pauses returns `{ error: "input_required" }` to its
  caller instead, without announcing the pause, and raises
  `Delegation::InputRequiredError` under `on_exceeded: :raise`. Supported by
  every built-in tool loop, streamed or not: Anthropic, OpenAI Chat
  Completions, OpenAI Responses (reasoning items included) and RubyLLM. Under a
  custom provider that does not run its calls through `dispatch_tool_calls`, a
  tool that asks raises `InputRequest::UnsupportedProviderError`.
- **Require approval before a tool runs** (`activeagent`). The
  `requires_approval:` prompt option lists tools whose calls pause with a
  `:confirm` request carrying the tool name and arguments before the tool runs;
  `true` runs it, `false` declines. It covers agent tools, delegations and
  client-side MCP tools, and is never sent to the provider. An MCP declaration's
  own `require_approval` (`"always"`, or a map of `always`/`never` tool lists)
  gates its tools the same way. A remote MCP server that may offer a listed
  tool runs client-side so that its calls are gated too: one whose
  `allowed_tools:` include the tool, or one without `allowed_tools:` when no
  tool in `tools:` has the name; `mcp_strategy: :server` with such a server
  raises `ArgumentError`, as does a `requires_approval:` value that is not tool
  names. A paused call to an MCP tool its server no longer offers returns an
  `{ error: }` result on resume.
- **Resume a paused generation in a job** (`activeagent`).
  `Generation#resume_later(checkpoint:, answers:, **job_options)` validates the
  answers, refuses any answer to a `:secret` request, and enqueues
  `GenerationJob` with a new `resume:` argument; params and actor travel as they
  do for `generate_later`. `InputRequest#arguments` holds the arguments of the
  paused call.

### Changed

- **`GenerationJob` no longer logs its arguments** (`activeagent`). They can
  hold a paused generation's conversation and the user's answers.
- **MCP declarations that set `require_approval` run client-side**
  (`activeagent`). On Anthropic and OpenAI Responses, a `url:` declaration whose
  `require_approval` is anything but `"never"` is served by ActiveAgent's MCP
  bridge rather than handed to the provider, so its calls can pause for
  approval; `mcp_strategy: :server` with one raises `ArgumentError`. Such
  servers now connect from your app and need `gem "mcp"`; set
  `require_approval: "never"` to keep one with the provider.

### Fixed

- **An owner of another class reads no other tenant's rows** (`actionagent`).
  `Ownable.for_owner` scoped by the owner's id alone, so an account-owned
  model handed a user — the stored provider-key fallback of an agent run,
  `ProviderKey.for_owner(agent.owner)`, when agents are owned per user — read
  whichever account shared that user's id, and the run generated with that
  account's key. The scope now matches the owner by class: a user handed to an
  account-owned model maps to its tenant through `ActionAgent.tenant_for`, and
  any other mismatch scopes to nothing. `TelemetryTrace.for_account` matches
  the same way, and `owner=` raises `ArgumentError` for an owner that resolves
  to nothing rather than writing its id into another class's column.
  **Upgrading:** a multi-tenant install that configures both `account_class`
  and `user_class` must own every model by one class or map between them.
  Re-declare `owned_by :account, :user` on `Agent`, `SandboxSession`,
  `SessionRecording` and `CodeSession` from `to_prepare` and set
  `tenant_resolver`, as the install generator's template now shows; rows those
  models stored under `user_id` with the account's id need `account_id`
  backfilled, or the dashboard lists nothing for them.
- **Fix Anthropic structured output mapping** (`activeagent`). Preserve caller
  `output_config` and ignore unsupported response formats.
- **Fix Anthropic JSON emulation on current models and with thinking**
  (`activeagent`). `json_object` requests reach current Claude models
  without a prefill, which they refuse with or without thinking, and so do
  requests with thinking on. The JSON is read from the answer, inside a code
  fence or not, and a retry drops an unparseable answer rather than ending on
  it. Claude 4.5 and earlier models keep the lead-in while thinking is off.
- **Prevent Anthropic response fields from leaking into replayed requests**
  (`activeagent`). Keep only request-supported message fields.
- **Name conflicting gems in provider load errors** (`activeagent`). Name
  `ruby-openai` and show the Gemfile replacement only when that gem is
  activated or defined `OpenAI`; when something else defines it, say where.
- **Start `command:` MCP servers that declare `env:`** (`activeagent`). The
  declaration's symbolized environment keys reached the process spawn, which
  requires Strings, so every stdio server that needed credentials in its
  environment failed with a TypeError.
- **Return an MCP server's JSON-RPC error to the model, marked as a failure**
  (`activeagent`). The client raises on an error envelope; the bridge hands
  the message back as the tool's result instead of failing the generation.
  That error, like a result the tool marks `isError`, reaches the model as
  `{"error": message}`, with `is_error: true` on Anthropic, so it no longer
  reads as a successful result.
- **Serve String-keyed `mcps:` declarations natively where the provider can**
  (`activeagent`). Keys are symbolized before partitioning, so a declaration
  loaded from YAML is no longer bridged on Anthropic or OpenAI Responses.
- **Keep credentials out of the `mcps:` declaration error** (`activeagent`).
  The message names the declaration's keys, not its values.
- **Refuse an unknown `mcp_strategy:`** (`activeagent`) instead of treating it
  as `:auto`.
- **Create the MCP tool cache's lock with the class** (`activeagent`), so the
  first concurrent callers share it.
- **Apply `read_timeout:` to `url:` MCP servers** (`activeagent`). The option
  was accepted on a remote server but neither validated nor applied, so its
  requests waited as long as Net::HTTP allowed. It is validated for both
  transports and sets the read timeout of the server's HTTP connection, 30
  seconds by default, so a streamed response stays open while it keeps sending
  events.
- **Bound a `command:` MCP server's whole answer by `read_timeout:`**
  (`activeagent`). The wait restarted with every frame read, so a server that
  kept sending notifications or pings without answering held the generation
  open indefinitely. A server that misses the deadline is stopped, and
  `MCPBridge::TimeoutError` names the server and the request. The handshake
  keeps the `mcp` gem's 5-second bound on its `server/discover` probe instead
  of waiting the full read timeout.
- **Name conflicting gems in provider load errors** (`activeagent`). Explain
  when another gem already defines `OpenAI` and show the Gemfile replacement.
- **Use an explicit OpenRouter key before the environment** (`activeagent`).
  An `api_key` or `access_token` passed to the OpenRouter provider wins over
  `OPENROUTER_API_KEY` and the other OpenRouter variables, as it does for the
  other providers. An explicit `api_key` is no longer dropped when no
  OpenRouter variable is set. A blank explicit key is also used as given, so a
  config value that renders as an empty string no longer falls back to the
  environment; leave the key unset to use the environment.
- **Use an explicit OpenAI project before the environment** (`activeagent`).
  A `project` or `project_id` passed to the OpenAI provider wins over
  `OPENAI_PROJECT_ID`, and an explicit `project_id` is no longer dropped.
- **Stop Session Replay spinning when there is nothing to play**
  (`actionagent`). With no recordings, a failed list request or a network
  error, the page shows the empty state, or an error when the list failed.
- **List only the session recordings the caller can open** (`actionagent`).
  The list uses the rule that opening a recording does, so a recording named
  `lander_demo` is no longer listed for every caller.
- **Replay every action of a long recording** (`actionagent`). Session Replay
  pages through `GET /api/session_recordings/:id/actions` with
  `after_sequence`, up to 5,000 actions, instead of stopping at the first 100.
  That endpoint's `has_more` is exact and its `limit` is clamped to 1..500.
- **Key show timeline entries `action_type`** (`actionagent`). They match
  `/actions` entries; `type` remains as an alias.
- **Accept reasoning items in streamed OpenAI Responses** (`activeagent`). A
  streamed response from a reasoning model raised `Unexpected Item Type`; its
  reasoning items are now kept and sent back with the function calls they led to.
- **Send each RubyLLM tool result as its own message** (`activeagent`). A turn
  with several tool calls sent their results merged into one message, under the
  first call's id.
- **Fix a forced Anthropic `tool_choice` failing on a third turn**
  (`activeagent`). Once the forced tool was used, the next turn cleared
  `tool_choice`, and the turn after it raised `Anthropic::Errors::ConversionError`
  reading the cleared value back.

## [1.8.1] - 2026-10-01

### Added

- **Every evaluation cost is priced, and says how** (`actionagent`,
  `activeagent`). A scenario result with no cost is priced down a chain —
  the cost the publishing application reported, the estimate the engine
  stored, the result's tokens × its model's rate, the tokens of the trace
  it links to, or its text at four characters a token as a lower bound —
  and a result that recorded no tokens costs `$0.00` (`cost_source:
  no_usage`); only a result with no tokens, no trace and no text stays
  unpriced. Results carry `cost` (the effective figure), `reported_cost`,
  `cost_source`, `cost_rate` and `judge_usage`; a run's `usage` adds
  `reported`, `estimated`, `cost_basis` and `total`; `scores._models` adds
  per model `reported`, `estimated`, `judge_cost` and `judge_calls`; and
  `GET /api/evaluations/:id/runs/:run_id` adds `costs` per scenario (judge
  apart) and for the run (`ActionAgent::EvaluationRunCost`, cached per
  finished run). The judge's spend is found the same way — the engine's
  meter, the application's figures (`result.judge_usage`,
  `report.judge_usage.run`, accepted by the report import) or the judge
  traces priced on input and output tokens, never thinking tokens — within
  the run's tenant. `ModelPricing` looks rates up under the provider the
  model ran on, strips gateway and vendor prefixes and date suffixes, tries
  dots and dashes both ways, prices `claude-sonnet-5` and the `gpt-5`
  family by exact rows ahead of the family patterns, and reports where a
  rate came from (`estimate_detailed`, `rate_detail`, `fingerprint`). The
  engine's judge meter counts Anthropic's cached prompt tokens.
- **One display format for passes, scores and costs** (`activeagent`
  `ActiveAgent::Evals::Format`). A fraction always carries its percent
  (`14/16 · 88%`; `14/16 (88%)` in Markdown; `—` for nothing scored), every
  0..1 score reads as a whole percent (`93%`, `pass ≥ 70%`), and money
  reads `$0.0243` when reported and `~$0.0243` when any part was estimated,
  with one legend per surface. The HTML report gains a Cost tile, a Judge
  column and per-model judge line, a trailing matrix Cost column with
  group subtotals, a cost line per cell and in each result's details, a
  judge chip with its calls and cost, a release chip, the pass mark and
  the cost in its footer; the Markdown report gains a Judge column, a
  matrix Cost column, the cost per answer and a total line. Diagnosis
  text reads `Task completion scored 60% against a pass threshold of 70%`.
- **Costs from replay metadata** (`activeagent`). A `Replay`'s metadata may
  carry `cost_source`, `cost_rate` and `judge_usage`; `Report#summary_by_model`
  adds `reported`, `estimated`, `judge_cost` and `judge_calls`,
  `Report#scenario_costs` gives each scenario's cost across models, and
  `Report#judge_usage` sums every result's judge calls with the run-level
  part passed as `Report.new(judge_usage:)`. `Report.new(release:)` (and
  `Runner.new(release:)`) names the release the run scored, in
  `to_h["release"]` and a header chip. `to_h` is unchanged when neither is
  given.
- **An evaluation's standing against the agent as it is now**
  (`actionagent`). Each evaluation reports its `headline_run_id` (its
  newest complete run; a newer pending or failed run shows beside it), its
  `standing` — `current`, `stale`, `unrecorded`, `archived` or `none`
  (`ActionAgent::EvaluationStanding`) — its `archived_at` and `per_model`
  passes, and every run its `agent_version` and `version_state`. Only
  model-facing edits (instructions, action prompts, tools, MCP servers,
  model config, response format) make a run stale. A published report's
  `report.release` pins the run to that release, recorded as a version when
  the dashboard has not seen the digest (`Agent#find_or_record_release!`,
  which never moves a deploy's `release_digest` backwards); a report with
  no release leaves the run unrecorded. `PATCH /api/evaluations/:id` with
  `evaluation: { archived: true | false }` archives an evaluation or brings
  it back; `GET /api/evaluations` leaves archived evaluations out before
  its 50-row limit unless `?archived=1`, and returns `archived_count`. A
  new run or a published report brings an archived evaluation back.

- Codex code sessions in checkout sandboxes. Connect an OpenAI API key under
  Settings → Integrations and select Codex in the code-session panel. The local
  backend runs `codex exec` with JSONL events, workspace-write sandboxing, stdin
  prompts, per-sandbox configuration, cancellation, timeout and diff capture.
- Explicit code-runner capability checks for host backends. Existing adapters
  continue to support Claude Code without implicitly receiving Codex credentials.

### Changed

- **The dashboard reads passes, scores and costs one way** (`actionagent`
  frontend). Every fraction carries its percent (`14/16 · 88%`), every 0..1
  score reads as a whole percent, and every cost reads `$0.0243` when
  reported or `~$0.0243` when any part was estimated, with the legend once
  per surface and the tokens × rate working in the figure's tooltip. The
  Evaluations page's tiles pool only the headline run of each current or
  unrecorded evaluation, show a pass line per model, and say how many
  evaluations were left out as stale or archived; a card carries its
  standing, an archive/unarchive control and, for a newer run still
  pending or failed, that run's badge beside the headline's; *Show
  archived (n)* lists the archived ones. The suite panel gains the spend
  strip between Runs and Models, the matrix a cost line per cell
  (`~$0.0243 · judge ~$0.0015`) and a trailing Cost column with group
  subtotals, the model comparison a Judge column, the runs list a version
  chip and a same-version / new-version / release-not-recorded line under
  each delta, and the spend strip reads the judge's cost from the traces
  and says "rules only" only when there is no judge. The agent cards'
  Eval tile is the pooled pass rate with its fraction in the title.
- **The agent card's Eval tile is the pooled pass rate** (`actionagent`
  `AgentScorecard`) over the headline runs of the agent's current and
  unrecorded evaluations — never a stale suite's or an archived one's —
  rather than the mean criterion score of whichever run was last.
  `eval_runs` and `eval_not_counted` say what was pooled and what was left
  out.
- **The partial-cost notes are retired** (`actionagent`, `activeagent`).
  The `*` marker and the "k of n priced" notes of 1.8.0's partial-cost fix
  give way to the `~` mark and its legend: a cost that covers only some of
  a model's replays is a lower bound and reads as an estimate. The verdict
  rationale reads `Passed 2 of 2 scenarios (100%) with a mean score of 100%
  at ~$0.0010 (estimated)`, and the judge ruling on a comparison is told
  each model's agent cost alone — never the judge's own spend, which never
  enters the ranking either. The HTML report's header shows a chip per
  scalar metadata value only: an array or object (the judge's trace ids)
  is no longer rendered as one.
- **What to fix comes after the scenario results** (`actionagent`,
  `activeagent`). A run report now reads models, then the scenario results,
  then What to fix. The scenario suite panel moves What to fix below the
  scenario matrix. The standalone HTML report
  (`ActiveAgent::Evals::ReportHtml`) moves its fix cards below the matrix and
  the per-scenario details. `Report#to_markdown` moves its Recommendations
  below its Answers. The sampling run detail already read in this order.
  Each section's content is unchanged.

### Fixed

- Inherited Codex settings and credentials are removed from sandbox process
  environments. Each Codex run receives only its owner's selected connection.

- **An evaluation's cost when some interactions carried no cost estimate**
  (`actionagent`, `activeagent`). A run's cost sums only the interactions that
  were priced, but its per-interaction rate divided that partial sum by every
  interaction, and nothing said part of the run was unpriced. The rate is now
  over the priced interactions, and a run's `usage` counts them: `priced` and
  `unpriced` beside `replays` (or `samples`). A run where nothing was priced
  reports no `cost` or `per_interaction`, as before, with `priced: 0`. The
  per-model summaries count them too: `Report#summary_by_model` adds `priced`
  per model and a sampling run's `_cohorts` add `priced` per cohort. A
  scenario run recorded before that has its `_models` counted from its
  results when the API serves it (`EvaluationRun#model_summaries`); a
  sampling cohort recorded before that reads as fully priced when it has a
  cost. The dashboard shows a partial cost as an estimate — "estimated, 3 of
  5 replays priced" — on the run's spend strip and footer, the model
  scorecards and the Evaluations page's cost-per-interaction tile, and marks
  it `*` in the runs list, the model comparison table and the spend strip's
  total, whose titles give the count. The HTML
  and Markdown reports and the pass-rate verdict name the priced count beside
  a partial cost, the judge ruling on a comparison is told it, and a
  pass-rate verdict breaks a tie on cost per priced scenario rather than on
  the partial sum, so an unpriced replay no longer makes a model look
  cheaper.

Upgrade both gems together, then run `bin/rails generate action_agent:install
--skip` and `bin/rails db:migrate`. The migration adds runner identity to code
sessions; existing sessions remain Claude Code sessions.

## [1.8.0] - 2026-09-29

Releases `activeagent` and `actionagent` 1.8.0 from one tag. A minor release.
Settings -> Integrations connects GitHub and Claude Code. A connected
repository's checkout boots as a sandbox, on a developer's machine with the new
`:local` backend, where Claude Code sessions run and an evaluation can run
against the checkout without the agent being edited. The dashboard's MCP
server gains evaluation and telemetry tools for a developer's own coding
harness. Ollama hosts can be tested and can be remote, with an optional Bearer
API key. Comparison runs lead with a per-model table and filter the fix list
by model. A publisher can check its collector before a run.

Upgrading: run `bin/rails generate action_agent:install --skip` and
`bin/rails db:migrate`. The generator adds what an install lacks:
`provider_keys.api_key` and the `github_connections` and `code_sessions`
tables. An app on the RubyLLM provider needs ruby_llm 1.16 or later; 2.x
works too.

The Claude Code connection stores Anthropic API keys only. Anthropic does not
let third-party products collect, store or route requests through Claude.ai
subscription credentials
([Claude Code legal and compliance](https://code.claude.com/docs/en/legal-and-compliance.md)),
so a `claude setup-token` token (`sk-ant-oat…`) is refused. An install that
stored one while running a pre-release build never hands it to a session: its
owner sees Claude Code as needing an API key (`needs_replacing: true` in
`GET /api/provider_keys`) until they paste one.
`bin/rails action_agent:claude_code:purge_subscription_tokens` deletes the
stored tokens and prints how many it removed. A developer who wants sessions on
their own Claude login sets `config.claude_code_auth = :local_login` with the
`:local` backend and runs `claude /login` on that machine instead.

### Added

- **Evaluation and telemetry tools on the MCP facade** (`actionagent`). The
  dashboard's MCP server now offers `evaluations_list`, `evaluations_get`,
  `evaluations_run`, `evaluation_runs_get`, `evaluation_runs_compare`,
  `traces_search` and `traces_get`, so a developer's own coding harness can
  run an agent's evaluations, read the fix items and failing traces, and
  iterate on the agent in its own checkout without the dashboard holding a
  model login. The tools read under the API key's owner exactly as the JSON
  API reads under the signed-in owner, run through the same execution,
  quota and sandbox checks as `POST /api/evaluations/:id/run`, bound their
  output, and mask the owner's credentials. Their names cannot collide with
  schema tools or agent tools. `ActionAgent.mcp_dashboard_tools = false`
  turns them off.

- **Local checkout sandboxes and Claude Code sessions** (`actionagent`, #489).
  A new `:local` sandbox backend (`config.sandbox_service = :local`) makes
  **Start sandbox** work on a developer's machine without containers. It
  clones the repository under `tmp/action_agent/sandboxes`, runs the setup
  the checkout's optional `.activeagents/sandbox.yml` names (`env`, `setup`,
  `manifest`, `start`), and boots the app on `127.0.0.1`. It then registers
  the app's MCP facade as the `sandbox:<session_id>` server. Every process
  starts from a sanitized copy of the dashboard's environment: without its
  database and Redis URLs, Rails keys and environment, Bundler and Ruby
  settings, git repository and config variables, `SSH_AUTH_SOCK`,
  model-provider and Claude Code settings, variables named like a secret, or
  URLs carrying credentials. The GitHub token reaches
  only the fetch, and the Claude Code API key reaches only Claude Code.
  `:local` runs the owner's code with the dashboard's privileges, so it is off
  outside development and test unless
  `ActionAgent.local_sandboxes_enabled = true`.
  - `bin/rails action_agent:sandbox:manifest` writes the booted app's
    `{mcp_path, mcp_token}` for the backend.
  - `bin/rails action_agent:sandbox:reap` expires overdue sandboxes and stops
    them.
  - A ready sandbox runs headless Claude Code sessions (`--permission-mode
    acceptEdits` by default). You start them from Settings -> Integrations, or
    through `/api/sandboxes/:session_id/code_sessions`. Their events stream
    into the dashboard, and the checkout's diff follows.
  - New options: `local_sandboxes_enabled`, `local_sandbox_root`,
    `local_sandbox_boot_timeout`, `claude_code_command`,
    `claude_code_permission_mode`, `claude_code_max_turns`,
    `claude_code_timeout` and `claude_code_auth`.
  - `claude_code_auth = :local_login` runs sessions on the machine's own
    Claude Code login (`claude /login`), with no stored key: the backend
    passes no credential and no `CLAUDE_CONFIG_DIR`, so `claude` uses the
    dashboard user's own `~/.claude` or keychain, which the dashboard never
    reads. `LocalSandboxBackend.claude_login_status` asks
    `claude auth status --json` (cached for a minute) and keeps only
    `loggedIn` and the login method. `GET /api/sandboxes` reports
    `claude_code_auth` and, in this mode, `claude_code_login`
    (`{ logged_in, auth_method }`), and the assistant's
    `connections.claude_code` the same as `auth` and `login`. Other backends
    refuse sessions in this mode (`code_sessions_supported: false`, and a
    `422` naming the reason).
  - `app_runtime` sandboxes now provision in the background and last 2 hours.
  - Run `rails g action_agent:install` to add the
    `create_active_agent_code_sessions` migration.
  - This repository's own `.activeagents/sandbox.yml` boots `test/dummy`.
  - Every `:local` sandbox boots on databases of its own, so a checkout of
    the dashboard's own app no longer migrates the developer's development
    database. The backend reads the adapter from the checkout's
    `config/database.yml` without running its ERB, and sets `DATABASE_URL`
    and `<NAME>_DATABASE_URL` (`QUEUE_DATABASE_URL`, `CACHE_DATABASE_URL`):
    SQLite files in the workspace, or `<database>_sandbox_<id>` on
    PostgreSQL and MySQL, which terminate drops with the checkout's
    Rails database tasks restricted to the names and URLs recorded at boot.
    Setting a variable in `sandbox.yml`'s `env` overrides it and excludes
    that database from cleanup. Replica mappings follow their own writer;
    ambiguous mappings require an explicit URL instead of guessing.
  - The Claude Code panel has a **Model** select: Claude Code's own
    default, the `sonnet`, `opus` and `haiku` aliases, or any model id under
    *Other…*. It remembers the last choice per browser, and each session
    shows the model it ran on.
  - A run can use a checkout sandbox without the agent being edited:
    `sandbox_id` on `POST /api/evaluations/:id/run` (and on the runner's
    `/api/agents/:id/execute` and `/test`) gives that run's tool dispatcher
    the sandbox's `sandbox:<session_id>` runtime, as if the agent listed it.
    The sandbox must be the caller's, a ready `app_runtime` sandbox, and the
    agent owner's; anything else is a `422`. The run records which sandbox
    it used (`run.sandbox`), and a scenario suite's **Run against sandbox**
    select, its Runs list and the run report show it. The selected sandbox
    takes precedence for matching tool names, with one schema per name.
    Queued agent runs fail if their selected sandbox stops, and failed
    sandbox discovery never silently falls back to the original tools.
- **Claude Code connection** (`actionagent`, #478). Settings -> Integrations
  stores an Anthropic API key (`sk-ant-api…`, from the Claude Console) as the
  `claude_code` provider key. It is encrypted, write-only, and not an agent
  provider. `SandboxSession#runtime_environment` hands it to an
  `app_runtime` backend as `ANTHROPIC_API_KEY`, so the checkout can run
  Claude Code sessions. Claude subscription tokens (`claude setup-token`)
  are refused, as Anthropic's terms require (see the upgrading note above).
  `/api/provider_keys` rows now carry `kind` (`key`, `host` or
  `connection`) and `needs_replacing`.
- **GitHub connections and checkout sandboxes** (`actionagent`, #477).
  Settings -> Integrations connects GitHub over OAuth
  (`ActionAgent.github_client_id` / `github_client_secret`, or
  `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET`), stores the token encrypted,
  and lets the owner choose which repositories the workspace may use. Only
  repositories GitHub lists for the token can be selected. A new
  `app_runtime` sandbox type checks out one of them: the backend receives
  `sandbox_session.checkout_spec` (repository, ref, clone URL, token),
  boots the app, and returns `mcp_url` / `mcp_token` from `create_sandbox`.
  The session is then an MCP server keyed `sandbox:<session_id>`. An agent
  that lists that key in `mcp_servers` runs, and is evaluated, with the
  checkout's own tools. Lookups are scoped to the agent's owner. Run
  `rails g action_agent:install` to add the
  `create_active_agent_github_connections` migration.

- **Ollama hosts are testable and can be remote** (`actionagent`). Settings ->
  Provider API Keys gains a **Test connection** for Ollama that reports
  whether the server is reachable, the round-trip time and the models it
  serves, before or after saving (`POST <mount>/api/provider_keys/test`,
  read-only). The host is accepted as a bare server address
  (`http://localhost:11434`; the OpenAI-compatible `/v1` path is added) and
  an optional **API key** is stored beside it and sent as a Bearer token,
  for a server behind an authenticating proxy or Ollama Cloud. The agent
  builder's live Ollama model list uses the same probe and key. When no host
  is configured the card shows the host app's `config/active_agent.yml`
  default. The install generator emits a guarded `add_provider_key_api_key`
  migration for existing installs; re-run
  `bin/rails generate action_agent:install --skip` and `bin/rails db:migrate`.
- **A model comparison table on comparison runs** (`actionagent`,
  `activeagent`). A run over several models now leads its Models section
  with one row per model, best first: passed, mean score, average latency,
  average tokens per scenario, cost (and per scenario), and the model's
  typical fault — its most frequent one with the diagnosis of a result that
  carries it. The scenario suite panel, the sampling run detail and the
  standalone HTML report (`ActiveAgent::Evals::ReportHtml`) all render it.
- **What to fix, filtered by model** (`actionagent`, `activeagent`). On a
  comparison run the fix list takes a model chip, narrowing to the items
  attributed to that model and counting what that model alone produced,
  since one model may need more instruction than another. The standalone
  report filters through radio chips and stylesheet rules — it still ships
  no script.

- **A publisher can check its collector before a run** (`activeagent`).
  `ActiveAgent::Evals::Publisher#verify!` asks the collector whether it is up
  and accepts the key before a run is paid for. It posts an empty JSON object,
  which a compatible collector refuses with a 422 naming `version`, without
  storing anything; anything else raises `Publisher::Error` with a delivery's
  status, detail and guidance. `Publisher#endpoint` returns the collector URL.

### Changed

- **Collector rejections say what the status means** (`activeagent`). A
  `Publisher::Error` for a 401, 403, 404, 415 or 501 rejection names a refused
  key, an account an operator must act on, an endpoint that is not a
  collector, a rewritten `Content-Type`, or an install with no evaluation
  store, in place of the generic guidance.

### Fixed

- **A nested scenario expectation written as one value** (`activeagent`).
  `ScenarioParser` now stores `{ expectations: { contains: "30" } }` as a
  list of one, the shape the persisted scenario and the dashboard's matrix
  read; an object-list import with a lone value used to break the suite
  panel. The matrix also tolerates scenarios persisted before this.

## [1.7.2] - 2026-09-29

Releases `activeagent` and `actionagent` 1.7.2 from one tag. A patch on 1.7.1:
the RubyLLM provider runs on ruby_llm 1.16 and 2.x, where 1.7.1 required 1.x.
Apps on the RubyLLM provider need ruby_llm 1.16 or later; earlier 1.x
releases lack the APIs the provider calls. No migrations.

### Changed

- **The RubyLLM provider supports ruby_llm 1.16 and 2.x** (`activeagent`).
  The adapter handles 2.x's tool interface, token limits, embedding model
  objects, usage and finish reasons while keeping the 1.16 API working.
  Requiring `>= 1.16, < 3` prevents Bundler from selecting an older 1.x
  release without the APIs the adapter calls. Rails main can now resolve
  RubyLLM 2.x alongside Active Storage's Marcel 2 dependency. CI also runs
  the full suite with RubyLLM 1.16 to retain coverage of that version.
  Unsupported-version errors name the loaded version and both bounds (#508).

## [1.7.1] - 2026-09-29

Releases `activeagent` and `actionagent` 1.7.1 from one tag. A patch on 1.7.0:
the Evaluations page picks the judge and compared models from the provider
catalogs, `GET /api/provider_models` lists the host's RubyLLM registry, and
the RubyLLM provider requires ruby_llm 1.x and sends tool calls and structured
output in the shape ruby_llm reads. No migrations.

### Added

- **Model pickers on the Evaluations page** (`actionagent`). The judge model
  and the models to compare, on the new-evaluation form and on a scenario
  suite, are chosen from type-ahead suggestions, and a model the suggestions
  lack can still be typed. The compare fields hold one removable chip per
  model and still submit the same comma-separated list.
  - With scenarios, the suggestions are the catalogs the agent builder uses,
    for the providers the owner's runs have credentials for. A model whose
    name alone would run elsewhere is offered with its provider in front, as
    `ModelSpec.parse` reads it: `ollama/llama3.2`, or
    `openrouter/anthropic/claude-sonnet-4.5` for OpenRouter's copy of an
    Anthropic model.
  - Without scenarios, a compared model selects the generations recorded
    under its name, usually the provider's dated id, so the suggestions are
    the names the agent's generations were recorded under, from the new
    `GET /api/agents/:id/recorded_models`. Adding or clearing the scenarios
    renames the catalog models already chosen to match.
  - The judge field suggests the models of the provider the judge runs on
    and says which provider that is, or that the credentials deciding it
    could not be read.

  `GET /api/evaluations` reports that provider as `judge_provider` and the
  providers runs can use as `model_providers`
  (`AgentExecutionService.available_providers`). Runs and their judge use
  the evaluated agent's owner's credentials, so both fields describe that
  owner's when `agent_id` scopes the list, and the signed-in owner's
  otherwise. `judge_provider` is null when no provider has credentials, and
  also when reading them raised, which `judge_provider_error: true` marks.
  `model_providers` leaves out a provider whose credentials cannot be read.
  Either way the list still loads.
- **`GET /api/provider_models` lists the host's RubyLLM registry**
  (`actionagent`). When the host app loads RubyLLM, the chat models its
  registry lists for the provider that take and return text (RubyLLM's
  bundled catalog, or the host's own model table) follow the live or curated
  list, each once, so the builder's preselected default is unchanged. That
  leaves out the speech, transcription, moderation and completion-only
  models RubyLLM counts as chat models, which its registry lists with no
  modalities or as taking audio, and with them the few chat models it lists
  with no modalities, which can still be typed. A registry that raises is
  logged and leaves the list as it was.

### Changed

- **The RubyLLM provider requires ruby_llm 1.x** (`activeagent`). ruby_llm
  2.0 renamed the APIs `RubyLLMProvider` calls, and the open `>= 1.0`
  requirement let `bundle update` install it. The provider now requires
  `~> 1.0` until it supports 2.0 (#502). Loading it with an unsupported
  version names the supported range and the loaded version, instead of
  asking for a gem that is already in the Gemfile. Pin
  `gem "ruby_llm", "~> 1.0"` if your bundle resolved 2.0.

### Fixed

- **Tool calls sent back through the RubyLLM provider** (`activeagent`).
  After a tool ran, the follow-up request repeated the model's tool call
  with its arguments as a JSON string where ruby_llm expects a Hash: OpenAI
  received them JSON-encoded twice, and Anthropic received a string for
  `tool_use.input`, which its API requires to be an object. The same
  happened when a stored conversation containing a tool call was replayed.
  The provider now hands ruby_llm the parsed arguments (#501).
- **Structured output through the RubyLLM provider** (`activeagent`). A
  `json_schema` response_format reached ruby_llm unchanged, but ruby_llm
  reads `{ name:, schema:, strict: }`, so OpenAI received a schema with a
  null name and body, and the Anthropic request raised inside ruby_llm
  before it was sent. The provider now converts it, naming the schema
  `response` and making it strict unless the format says otherwise, as
  ruby_llm's own `with_schema` does. A `text` format asks for plain text;
  `json_object`, which ruby_llm has no mode for, and a `json_schema`
  without a schema now raise `ArgumentError` instead of sending a request
  the API rejects (#501).

## [1.7.0] - 2026-09-24

Releases `activeagent` and `actionagent` 1.7.0 from one tag. A minor release:
a mounted engine collects the evaluation reports applications publish with
`ActiveAgent::Evals::Publisher`, whose failures now say what the collector
refused and whether to retry; observed agents read their own traces in
evaluation criteria, the Tools and Traces tabs and deploy markers; host apps
extend the engine's models and controllers through concerns and mirror their
agent classes into the dashboard; and the Evaluations page is rebuilt around
runs. Run the install generator after upgrading (see Upgrading below).

Upgrading: the install generator emits two new migrations, both guarded
column by column: `ensure_agent_release_columns`, which adds the agent release
columns an install generated fresh on 1.6.2-1.6.4 never got (and those on
tables with a custom `table_name_prefix`), and `add_evaluation_report_identity`
for the evaluation report collector. Re-run
`bin/rails generate action_agent:install --skip` (`--skip` keeps your
initializer) and `bin/rails db:migrate`. A traces-only install needs neither;
if you re-run the generator there, pass `--traces_only` again, or it emits the
whole dashboard schema. Nothing else changes until an application publishes a
report to the mount.

### Added

- **Host concerns for the engine's models and controllers** (`actionagent`).
  `ActionAgent.model_concerns` is included into
  `ActionAgent::ApplicationRecord` as it loads, and so into every engine
  model; `ActionAgent.controller_concerns` into
  `ActionAgent::ApplicationController`, ahead of its own callbacks, and so
  into every dashboard controller. (The ingest endpoint,
  `Api::TracesController`, inherits `ActionController::API` and keeps its
  own bearer-token authentication; it is not touched.) Entries are modules
  or their names, resolved
  when the class loads. A host that pins the engine's tables to one database
  connection, or carries its session helpers onto the dashboard's
  controllers, configures that here instead of reopening the classes from a
  `to_prepare` block.
- **The Evaluations page is rebuilt around runs** (`actionagent`). Evaluations
  are the top level; every run is kept and listed with its movement against
  the run before it (`+3 passed vs #2`, `partial run`, `#1 failed`), and a
  sampling evaluation's run opens to a page of its own at
  `<mount>/evaluations/:id/runs/:run_id` — a scorecard per model cohort, the
  judge's verdict, the criteria × models matrix and what the run asks to fix.
  A scenario suite's runs are the same full-width list; a row selects the run
  the suite's model scorecards, fix items and scenario matrix show.
- **What a run cost is two figures, not one.** The agent's spend — what the
  replayed or sampled interactions cost to serve, with a `per_interaction`
  rate, the operating cost a per-conversation budget is set against — is
  reported apart from the judge's, the judge model's own calls, which run
  agent-to-agent and offline. Every judge call is metered under what it was
  for (`scores["_judge_usage"]`: calls, tokens, estimated cost and how many
  calls scored, recommended, ruled or authored KPIs), and `EvaluationRun#usage`
  carries both sides. The page shows them on every run row, on the run, on a
  page tile and in the footer, so the cost of operating an agent is never
  inflated by the cost of checking it.
- A generation-sampling run records `scores["_cohorts"]`: per model, how many
  generations were sampled, how many cleared every criterion, their latency
  and tokens, and what those interactions cost to serve.
- `GET /api/evaluations` carries `run_count` and a `previous_run` summary per
  evaluation, and every serialized run its `number` in the evaluation's
  history, oldest first.
- The dashboard's object lists hold their metric columns in place: a trace,
  interaction or evaluation run with nothing in a column prints a dash there
  rather than sliding its neighbours over (`MetaStrip`).
- `ActiveAgent::Base.rendered_instructions` renders an agent's instructions
  outside a generation, for a dashboard mirroring the class and for tests
  asserting what a model is told. Both otherwise reached a private renderer
  through `send`.
- `ActionAgent::AgentSync` mirrors host agent classes into dashboard `Agent`
  records, setting the `agent_class_name` that `AgentRelease` already expects a
  host to have written. The code owns what an agent is (name, description,
  instructions, tools — rewritten every sync); the operator owns how it runs
  (provider, model, status — set on create and preserved), so a model chosen in
  the dashboard survives the next deploy.
- `ActionAgent.run_host_agent_classes` (default `false`) runs an agent that
  mirrors a host class as that class, rather than as one rebuilt from the
  record's `tools` and `instructions` columns. Dashboard-authored agents, which
  name no class, keep using the dynamic runtime either way; a class name that no
  longer resolves falls back to it rather than failing the run.
- MCP servers take `allowed_tools` and `require_approval` in the common
  format. OpenAI's Responses API receives both as given; Anthropic receives
  `allowed_tools` as an `mcp_toolset` entry in `tools` (every other tool of
  the server disabled), beside any tools the request already declares
  (#328, by @dark-panda).
- **A mounted engine collects published evaluation reports** (`actionagent`).
  An application that runs its agents itself and evaluates them in-process
  publishes the finished report with `ActiveAgent::Evals::Publisher`; until
  now a self-hosted install had nowhere to receive it. On a full install (not
  one generated with `--traces_only`, which answers 501),
  `POST <mount>/api/evaluation_reports` takes the version-1 envelope and
  returns the receipt the publisher checks, and
  `ActionAgent::EvaluationReportImport` stores it as the engine's own rows:
  the observed agent for the report's `source` and `agent_name`, an evaluation
  named for its suite and scope (`orders (eu, support)`), its scenarios, and a
  complete run with a result per scenario and model. The Evaluations page
  shows it the way it shows a run the dashboard executed, with the summary
  recomputed from the stored results. The endpoint authenticates exactly as
  trace ingest does (`ingest_api_key`, or the tenant's key in multi-tenant
  mode), takes only `application/json`, and places a report's agent wherever
  `trace_owner_resolver` puts that tenant's traced agents. A `run_id` is
  stored once per tenant, or once per install, and compared exactly: 201 for a
  new report, 200 for an identical retry, 409 for different content. Invalid
  reports, and an evaluation name the report does not own, are 422; a cap an
  operator has to lift (observed agents per owner, 100 evaluations per agent,
  2,000 scenarios per evaluation) is 403; a new report over the new
  `:evaluation_report` quota kind or past 30 new reports a minute from a key
  is 429. An identical retry is never refused by the quota or the rate limit.
  Bodies over 2 MiB are 413, and Rails never parses the body into params, so
  nothing past the limit is read. `usage_recorder` is told
  `:evaluation_report` for each stored report. Evaluation runs gain
  `external_tenant`, `external_run_id` and `external_report_digest`, unique on
  the first two (binary on MySQL); see Upgrading above.
  `docs/evals/publication.md` documents the endpoint.

### Changed

- The engine's judge blocks take `ActiveAgent::Evals::Judge`'s `kind:`, so a
  scenario run's score, recommendation and verdict calls are metered apart.
- `ActionAgent::TelemetryTrace` inherits `ActionAgent::ApplicationRecord`
  like every other engine model (`actionagent`), so it carries the model
  concerns above, `AdapterAware` and the ownership API (`owner_association`,
  `for_owner`) from the same place. Its table name is unchanged.
- `Api::TracesController`'s bearer authentication and its 429 quota body
  live in `ActionAgent::Api::IngestAuthentication` (`actionagent`), which the
  evaluation report collector shares. A host subclass that overrides
  `authenticate_api_key!` is unaffected. The tenant's
  `increment_telemetry_usage!` is still called for each trace ingest request,
  and not for a report post.
- `add_agent_releases` reads `ActionAgent.table_name_prefix` for the tables
  it alters (`actionagent`), so a newly generated copy works on an install
  with a custom prefix. The trace table keeps its fixed name.
- A collector's rejection of `ActiveAgent::Evals::Publisher` says what it
  refused and whether to retry. The message carries the `error` string of a
  JSON object response body beside the HTTP status — control characters and
  runs of whitespace collapsed to one space, the API key replaced with
  `[FILTERED]`, cut to 200 characters; nothing else from the body — and what
  to do next: never retry the report under the same `run_id` on a 409,
  publish a smaller selection on a 413, correct the report on a 422, retry
  later on a 408, 429 or 5xx, and resolve the cause first on anything else,
  such as a 401 or 403. `Publisher::Error` carries `status`, `detail` and
  `retryable?`.

### Deprecated

- Assigning `ActionAgent.base_controller_class`, which has never been
  consumed, warns through `ActionAgent.deprecator` and points at
  `controller_concerns`. The accessor is removed in 2.0.

### Fixed

- Telemetry criteria (`trace_error_rate`, `trace_latency`) score an observed
  agent from its own traces (`actionagent`). They selected traces by
  `Agent#telemetry_agent_class`, which appends `Agent` to a class name
  lacking it, so an agent observed from an application reporting `SupportBot`
  found no traces and scored nothing, and observed agents of one class ending
  in `Agent` read each other's actions. `Agent#telemetry_traces` selects the
  traces `AgentRegistrar` attributed to the agent, plus unattributed ones with
  its service, class and action. Deleting an observed agent leaves its traces
  unattributed, so the agent registered again for them still reads them. The
  agent's Traces tab, its Tools tab usage
  columns and the Interactions list filtered to it use the same selection. The
  Traces tab asks for it with `GET /api/traces?agent_id=`, which answers 404
  for an agent the caller cannot see; `agent=` still filters by class. On the
  Metrics page filtered to a class, an observed agent's deploy markers now
  show under the class its traces report (`Agent#reported_agent_class`).
  Authored and mirrored agents read the traces they did before.
- `Agent.prompt(...).generate_later` and `Agent.embed(...).embed_later` run
  their job instead of raising `ArgumentError: unknown keywords` in the
  worker (#346).
- The agent builder and editor can reach every model a provider serves: the
  OpenRouter catalog is no longer cut to its first 100 ids, and the model
  field is a type-ahead over the catalog that also takes an unlisted id
  (`actionagent`, #427).
- A rejected Create Agent shows its validation errors on the builder — a
  summary and a message under each field — instead of leaving the form
  silently in place. `POST`/`PATCH /api/agents` 422s carry `field_errors`
  beside `errors` (`actionagent`, #426).
- An engine agent is refused a provider whose client gem the host has not
  installed (`openai` for OpenAI, Ollama and OpenRouter; `anthropic` for
  Anthropic) when the provider is chosen, with a validation error naming
  the gem, instead of failing on its first run (`actionagent`, #416).
- A fresh `action_agent:install` creates the agent release columns with the
  dashboard tables (`actionagent`): `release_digest` on agents,
  `release_digest` and `revision` on agent versions, and `agent_version_id`
  on agent runs and evaluation runs. The generator emits `add_agent_releases`
  before the create-table migration, so on a fresh install it found none of
  those tables and added nothing, and creating an agent run or an evaluation
run raised `NoMethodError` on `agent_version_id`. An install generated
that way on 1.6.2-1.6.4 gets the columns from the new
`ensure_agent_release_columns` migration (see Upgrading above).
- Every failure of `ActiveAgent::Evals::Publisher` to deliver a report
  raises `Publisher::Error`. A malformed response (`Net::HTTPBadResponse`,
  `Net::HTTPHeaderSyntaxError`, or a `Zlib::Error` from corrupt compression)
  escaped as its own class and is now a retryable `Publisher::Error`. A
  report that cannot be encoded as JSON (invalid UTF-8, `NaN`, nesting too
  deep) is now a non-retryable one raised before anything is sent: it escaped
  as `JSON::GeneratorError`, or was blamed on the collector as invalid JSON.
  Only a network failure keeps its underlying error as `cause`, so a response
  body or report content never reaches a log through the exception chain.
  Invalid arguments raise `ArgumentError`, now also for a `report` that does
  not convert to a hash (a string raised `NoMethodError` and `nil` published
  an empty report) and a `nil` timeout (`TypeError`).
- The publisher strips whitespace around its API key, so the key it sends is
  the one it filters from a collector's explanation, and refuses a key with
  characters other than visible ASCII.

### Security

- The dashboard's JSON API verifies the CSRF token (`actionagent`, #461). It
  authenticates with the host's session cookie but had opted out of forgery
  protection. The dashboard now sends the page's token with every mutating
  request from one fetch shim; the MCP facade and trace ingest, which
  authenticate by bearer token, stay exempt. A rejected request answers
  `422` with `code: "invalid_csrf_token"`. Hosts that re-enabled protection
  themselves (`ActionAgent::Api::BaseController.protect_from_forgery`) can
  drop that line.

## [1.6.4] - 2026-09-22

Releases `activeagent` and `actionagent` 1.6.4 from one tag. A patch on 1.6.3
carrying one fix to `SchemaTools`, for a filter that answered confidently and
wrongly instead of failing.

### Fixed

- A Rails enum is offered to the model as its names (`{type: "string", enum:
  [...]}`) instead of the integer backing it. `SchemaGenerator` reads enums from
  inclusion validators and never consulted `defined_enums`, so a `status` column
  reached the model as a bare integer with no labels.
- A filter value outside an enum — alone or inside an IN list — is rejected,
  naming the valid values, instead of matching no rows. `status: "pending"`
  returned `{count: 0}`, which an agent reports as a fact, indistinguishable
  from "none match". Same reasoning as the unknown-operator rejection in
  `range_predicates!`.
- An enum is no longer offered the range form. Its integer backing is a
  declaration-order artefact, so `status: {gt: 1}` was a meaningless filter that
  still returned a confident count.

## [1.6.3] - 2026-09-18

Releases `activeagent` and `actionagent` 1.6.3 from one tag.

A release about telling the truth on the screens that report what happened.
The context meter now divides the provider's own `prompt_tokens` among its
segments instead of subtracting estimates from it, and sizes each piece —
tool schemas, MCP schemas, instructions and the transcript — before the span
clips it for storage; previously a trace with dense tool schemas showed a
large message history that was never sent. An adapted replay is metered as
one execution like any other, so a host that supplies its own runtime is no
longer silently uncounted, and a spec naming a provider the agent cannot
serve now fails before the replay rather than reaching it.

Three seams hosts were reaching around become API. `ActiveAgent::Evals::Correlation`
joins `Runner`'s `around_evaluation:` hook to a telemetry backend's trace
scope, so a report row links back to the conversation behind it. A `Judge`
block that accepts `kind:` is told whether it is scoring, recommending or
writing the verdict, instead of matching on the gem's own instruction prose.
`Agent#generations` replaces the polymorphic join hosts were copying out of a
private service method.

Upgrading: no migration, and nothing that already worked changes. The judge
keyword reaches only a block that asks for it, so existing judges are
untouched; `Evaluation#replace_scenarios!` keeps `:destroy` as its default.
Adapters should drop any `ActionAgent.record_usage` call of their own, which
now double-counts, and any provider allow-list check of their own, which is
now dead code.

### Added

- The prompt span records how large the tool schemas actually are, as
  `prompt.input.tools.tokens`, `prompt.input.mcp_tools.tokens`,
  `prompt.input.instructions.tokens` and `prompt.input.messages.tokens`. The
  transcript's size is measured before the span trims the history to the turns
  that fit, the others before their content is clipped. The content attributes
  beside them are previews clipped for storage — and on the SDK path the tool
  attribute is a roster of names and parameter keys, several times smaller than
  the schema the model is sent — so a reader that sized the context from one
  understated tool pressure badly.
- MCP tool schemas are attributed apart from the toolbox's, so the context meter
  can name which half fills the window.
- `Evaluation#replace_scenarios!` takes `on_removed:` — `:destroy` (the
  default, unchanged) or `:disable`, which keeps a scenario the suite no
  longer names as `enabled: false` so earlier runs' results still resolve.
- **An evaluation's traces link back to the result that caused them.**
  `ActiveAgent::Evals::Correlation` joins two APIs the module already had but
  never connected: `Runner`'s `around_evaluation:` hook and its `metadata:`
  run identity, and a telemetry backend's per-block agent scope. A run mints a
  `run_id`, each evaluation a `result_id`, and both ride every trace opened
  inside them as `eval.`-prefixed attributes; the trace ids travel the other
  way onto `result.replay.metadata` — `trace_id` for the replay,
  `judge_trace_ids` for the judge calls that graded it, with a run-level
  verdict landing on the run metadata the Report carries rather than on
  whichever result was evaluated last. The tracer is injected, so the module
  takes on no telemetry dependency and `require "active_agent/evals"` still
  loads on its own. Hand the object to `Runner.new(around_evaluation:)`
  directly; a plain lambda there keeps working unchanged.
- A `Judge` block that accepts `kind:` is told which of the judge's three calls
  it is serving — `:score`, `:recommend` or `:verdict` — so a host can trace,
  budget or model them separately. Previously the only signal was the
  `instructions` string, so hosts matched against the gem's own
  `RECOMMEND_INSTRUCTIONS` / `VERDICT_INSTRUCTIONS` constants; rewording one
  then sent every such host quietly down its `else` branch, mislabelling traces
  rather than failing. The keyword reaches only a block that names it or
  collects `**`, so judges taking `instructions:` and `prompt:` are unaffected.
  (#462)
- `Agent#generations` reads the generations recorded against an agent, with
  `Agent#agent_contexts` beside it. Generations hang off `AgentContext`
  polymorphically, so reaching them meant hand-writing that join — the engine
  did it itself in a private service method a host could not reuse, which now
  uses the association instead. Destroying an agent still leaves its contexts
  alone, as it always has. (#464)

### Fixed

- The dashboard's context meter divides the provider's own `prompt_tokens`
  among its segments instead of subtracting its estimates from it. Charging the
  difference to one segment made "Messages" absorb the whole approximation
  error, so a trace with dense JSON tool schemas read as a large message history
  that was never sent. The transcript is one of the divided segments: dividing
  only the rest would hand its share to the segments that remained, so a long
  conversation reported an enormous system prompt and no history at all.
- A host that supplies a `scenario_evaluation_adapter_resolver` now has its
  replays metered as executions, one per scenario x model, the same unit the
  default path records. Previously an adapted replay was counted only if the
  host remembered to call `ActionAgent.record_usage` itself.
- A scenario evaluation whose selected models name a provider the agent cannot
  serve fails with `ArgumentError` before any replay runs. A spec handed back
  as a Hash naming both `provider` and `model` bypassed the `providers:`
  allow-list, so the run reached the replay with a provider nothing serves.
## [1.6.2] - 2026-09-16

Releases `activeagent` and `actionagent` 1.6.2 from one tag.

Agents gain releases: a digest of everything the model is given, cut on
deploy and pinned to every trace, run and evaluation run, so a score is a
statement about a specific release and a regression is attributable to the
change that caused it. Around it, five dashboard fixes: an evaluation
created on MySQL can be run, the Tools tab reads the same `agent.tools` the
runner does, a container-valued query parameter is coerced instead of
raising, a recording's detail response no longer carries the visitor's
cookies and web storage, and the MCP endpoint answers an unsupported method with 405
instead of the dashboard page. `sign_in_path` and `sign_out_path` are now
documented.

Upgrading: the install generator emits a new `add_agent_releases` migration
(guarded column by column); run it. Cutting a release is
`rake action_agent:agents:release[REVISION]` in the deploy.

### Added

- **Agents have releases, and every trace, run and evaluation says which one
  it ran under.** `ActiveAgent::Release` gives each agent class a digest of
  what the model is given — provider and model, generation options minus
  credentials, the actions, the prompt templates on disk, and the tools and
  delegations it declares — so two deploys of the same agent share a digest
  and any change to those inputs is a new one, with no number to bump.
  `ActiveAgent::Release.revision` carries the deploy alongside (a git SHA;
  read from `SERVICE_VERSION`, `GIT_SHA`, `KAMAL_VERSION` and friends when
  not set). The instrumentation stamps `agent.version` and `agent.revision`
  on every generation's root span, and every trace gets `service.version`.
  In the dashboard, `rake action_agent:agents:release[REVISION]` cuts an
  `AgentVersion` for each agent whose code changed since the last release —
  idempotent, so it belongs in the deploy — `rake action_agent:agents:versions`
  lists them, and `Agent#record_release!` is the call behind both for a host
  that syncs agents its own way. Traces are pinned to the release their root
  span names, runs and evaluation runs to the version current when they
  started (`agent_version_id` on all three; the install generator emits the
  migration). A version's JSON carries `release`, `release_digest` and
  `revision`, so the Versions tab tells a deploy from an edit. For that to
  reach a host's own agents, a trace from a class the host mirrors into the
  dashboard is now attributed to that mirror — the registrar matched only on
  service, class *and* action, so every code-path trace registered an
  observed per-action twin beside the synced record and could never be
  pinned to its release.

### Fixed

- **An evaluation created on MySQL can be run.** MySQL cannot give a JSON
  column a default, so an evaluation saved there without `config` read it
  back as `nil`, and `compare_models` raised before the runner did anything
  else. `config` and `criteria` now read as the empty value their column
  default supplies on other databases. (#417)
- **The Tools tab now says which schema tools an agent is offered, and
  lets you change it.** The editor listed every schema tool as enabled and
  read-only whatever `agent.tools` held — *"a checkbox that cannot add or
  remove the tool is a control that changes nothing"* — while evaluations,
  dashboard runs and the MCP facade offered exactly what that column named.
  An agent whose roster had been emptied over the API ran a suite with no
  tools (1/8, `expected tool not called ×6`) under a tab reading "12
  enabled". A schema tool's row now reads the roster and is switchable, and
  every schema tool the host declares has a row, off unless the roster names
  it — any agent may enable any of them, and a tool switched off has to keep
  its row to be switched back on. A tool the agent class declares in code is
  still reported rather than selected: the class offers it, and no checkbox
  could change that.
- **A container-valued query parameter no longer 500s the dashboard API.**
  `page`, `per_page`, `days`, `minutes`, `limit` and `after_sequence` were
  read with `to_i`, which neither an Array (`minutes[]=1&minutes[]=2`) nor a
  nested object (`page[x]=1`) answers. `Api::BaseController` now coerces
  them: a multi-valued parameter means its first value, a nested object falls
  back to the default, and the clamps that bounded the number still apply.
  `sandboxes#compare` answers a `providers` value that is not a list of
  names with a 400 instead of a `NoMethodError`.
- **A session recording's `show` no longer returns the visitor's cookies and
  web storage.** Every other read path redacted the handoff state, but the
  detail response carried `cookies`, `session_storage` and `local_storage`
  unscrubbed, both as its own key and nested inside `metadata`. Both are now
  stripped; only `#handoff` returns them, to the recording's owner. (#456)

## [1.6.1] - 2026-09-16

Releases `activeagent` and `actionagent` 1.6.1 from one tag.

A patch for two defects that share a failure mode: each one turns a broken
run into a plausible-looking success rather than an error. A date filter that
matched nothing reported zero instead of raising, and an agent reported that
zero as fact; telemetry that was enabled but never instrumented wrote no
traces while every configuration signal read healthy. Neither surfaced in a
test suite, because neither produces a failure — only a confident wrong
answer and an empty table.

No new public surface and no behaviour change for anything that was already
working, so a patch under semver. Suites that filter on a date column will
report different — correct — numbers after upgrading; read the first run as a
corrected baseline.

### Fixed

- **A range filter on a `SchemaTools` column no longer matches nothing and
  reports zero.** `permitted_filters!` validated the column against the
  allowlist but passed the value through untouched, so a range hash reached
  `where` unrecognized and Rails compiled `where(due_date: {"before" => x})`
  to `due_date = NULL` — a predicate that matches no row. The tool returned
  `{count: 0}` with no error and the model read it as a truthful empty
  answer: "0 overdue tickets" against a database holding four. Equality
  filters were unaffected, which is why this went unnoticed. Comparisons are
  now built through Arel with the column's own type cast, under the operators
  `before`, `after`, `lt`, `lte`, `gt`, `gte`, `on_or_before` and
  `on_or_after`; two bounds may be given together to express a window; and an
  operator outside that set raises `UnpermittedAttribute` rather than
  returning zero, consistent with how an undeclared column is already
  rejected. Ranges are offered for date, datetime, time and numeric columns
  only — a lexical `>` on a name column answers a question nobody asked.
- **A range filter is now discoverable.** `filter_properties` described a date
  column as a bare `{type: "string", format: "date"}`, so the tool surface
  could not express "before today" at all and a model asking the question
  correctly still had no way to ask it. Comparable columns are now offered as
  `anyOf: [scalar, range object]`, with the operator roster in the schema.
- **Telemetry enabled from a host app's initializer now installs
  instrumentation.** The railtie prepended `GenerationInstrumentation` only
  when `Telemetry.enabled?` was already true as railties ran — before
  `config/initializers/*.rb`. An app that configures telemetry in its own
  initializer, which is what the documentation shows, was therefore never
  instrumented: `enabled?` answered true, `local_storage` was on, the trace
  model resolved and the store lambda worked when called directly, and no
  generation ever produced a span to store. `configure` now installs as well
  when the resulting configuration is enabled; `instrument_telemetry!` is
  idempotent, so the railtie path and the configure path cannot
  double-prepend and initializer order stops mattering.

## [1.6.0] - 2026-09-14

Releases `activeagent` and `actionagent` 1.6.0 from one tag.

A minor, not a patch. The cycle that began after 1.5.2 gives an agent a
caller — `current_user`, carried from whatever authenticated the call into
every `before_action`, every tool, every delegated sub-agent, every run over
MCP and every evaluation replay — so an authorization gem has something to
decide against. Around it: schema tools defined at runtime rather than only
in a file, a generator that writes the first one, those tools served
directly over MCP, and an evaluation that calls a fabricated answer a fault
instead of grading it as an honest gap. That is new public surface in both
gems, which is a minor under semver even though 1.5.2 shipped a feature as a
patch.

Two notes for upgrades. `tools_succeeded` is now awarded only for a tool the
scenario expected, so a suite that was quietly scoring wrong-tool runs as
partial successes will report lower — read the first run as a corrected
baseline. And `actor:` is now stripped from tool arguments and from
`params[params][actor]`: the caller is a property of the run, set once by
whatever authenticated it, and can no longer be named by the model or by a
client.

The engine's floor on the framework (`activeagent >= 1.4`) is unchanged and
still correct: 1.6.0 satisfies it.

### Added

- **An evaluation replay runs as the evaluation's owner.** The scenario runner
  handed `Agent#test_execute` no caller, so every tool a replay called ran
  unattributed and a host scope answered empty — the suite graded an agent
  that never saw a row. When agents are owned per user, a replay now runs as
  the user who owns the evaluation, as a run over MCP runs as the key's
  owner. A multi-tenant install still replays unattributed (an account is who
  is billed, not who is allowed) unless a host adapter runs the suite itself.
- **The MCP facade serves the host's schema tools directly.** `tools/list`
  at `POST <mount>/mcp` now offers every tool the dashboard's discovered
  `ActiveAgent::SchemaTools` classes generate — `find_<records>`,
  `count_<records>`, `get_<record>` — beside the `run_<slug>` agents, each
  with its own parameter schema, and `tools/call` runs one as the key's
  caller through the host's own scope, exactly as it would inside an agent
  run. A client that only needs the rows no longer has to ask an agent for
  them. A boundary violation is a tool result with `isError`, a refusal from
  the host's scope is a JSON-RPC `-32003`, and neither the execution switch
  nor the execution quota applies, because nothing generates. Set
  `ActionAgent.mcp_schema_tools = false` to keep the tools reachable only
  through agents. Closes #439.
- **A delegated run inherits its parent's caller.** `delegate_to` hands the
  sub-agent the parent's `current_user` before its action runs, so its own
  `before_action` callbacks and any scope its tools read through decide
  against the same person. A parent authorized as one user no longer hands
  its specialists an unattributed run — which a correctly written host scope
  reads as "no access", a wrong answer wearing a right one's clothes. A
  parent with no caller still delegates an unattributed run, never someone
  else's.
- **`rails generate active_agent:schema_tools Reservation`** writes a starter
  `ActiveAgent::SchemaTools` class under `app/agent_tools`. It exposes nothing
  beyond `id` until a column is moved into `filterable` or `returns`; every
  column the model has is listed, commented out, with its type, so the
  allowlist is a review step rather than a blank page, and columns that look
  like secrets are left off the list. Reads are scoped through
  `<Model>Policy::Scope` when it exists (`--policy` / `--no-policy` decide
  explicitly). This is #440's second option: the roster is still declared,
  once, but the declaration is no longer written from scratch. (#440)
- **An agent knows who it is running for, so an authorization gem has
  something to decide against.** `ActiveAgent::Base#current_user` carries the
  caller, assigned by whatever authenticated the call
  (`MyAgent.as(current_user).ask(...)`) and readable from every
  `before_action`, so Pundit, CanCanCan or Action Policy authorize an agent
  the way they authorize a controller. A refusal inside a tool call is
  returned to the model as `{ error: ... }` so it can say it is not allowed;
  a refusal anywhere else is raised to the caller. `denies_with` names a
  gem's own error as a refusal.
- **The dashboard fills that seam.** A run records the caller that started it
  (a Global ID, so a worker on another machine authorizes as the same
  person), passes it to every tool as `actor:`, and runs the agent through
  `as(actor)` — which is what a `SchemaTools` `scope` block has been waiting
  for since 1.5.0. `ActionAgent.agent_actor_resolver` overrides who that is.
- **Agents reached over MCP run as the key's caller** rather than
  unattributed, and an agent that refuses answers as a JSON-RPC error
  (`-32003`) instead of as an empty result.
- **Schema tools can be defined at runtime.** `ActiveAgent::SchemaTools.define(Reservation,
  filterable:, returns:, scope: | policy:)` builds the same bounded roster a
  file under `app/agent_tools` would — same allowlists, same `call`, named
  `ReservationTools` for logs — from a declaration held anywhere: a table, a
  dashboard form, a test. The class is registered under its model and a
  redefinition replaces the previous one, so a registry rebuilt on every
  change holds one class per model; `undefine` drops it. The dashboard
  discovers registry entries beside the files and lets a runtime definition
  supersede a file for the same model. What is persisted, and where, stays the
  host's decision; this is the seam a persisted declaration builds on. (#441)
- **A fabricated answer is now a fault.** `Diagnosis` raises `ungrounded_answer`
  when an agent that had tools called none, did not say it could not answer,
  and still stated specifics — a count, a record id, a date — that no tool
  supplied. Where the scenario names an expected tool, `expected_tool_not_called`
  says the same thing in its summary and carries `ungrounded: true`, so an
  invented answer no longer reads like an honest gap. Both reach the judge,
  which is what turns them into a suggested tool. An agent with no tools at all
  is not flagged: it answers from its instructions by design, and whether that
  is acceptable is the judge's grade, not a mechanical one. (#433)

### Changed

- **A wrong tool no longer outscores no tool.** `tools_succeeded` is awarded
  only for a tool the scenario expected (or any tool when it expects none):
  a tool that ran without erroring was evidence of the task only by accident,
  and a scenario that called the wrong tool scored higher than one that called
  nothing. (#433)
- **The judge reads more of a scenario's notes** — 1,500 characters rather
  than 300 — because a suite's notes are often its rubric and the "must not"
  clause tends to come last. (#433)

### Fixed

- **The caller can no longer be named by the model, or by the client.**
  `actor:` reached `AgentToolbox.call` in the same keyword namespace as the
  arguments a provider parsed out of a model's tool call, and
  `params[params][actor]` in an execute request would have won over the
  controller's own. Both are now stripped: the caller is a property of the
  run, set once by whatever authenticated it. Scoped `SchemaTools` reads are
  also excluded from the tool-result cache, so one caller's rows are never
  replayed for the next.
- **A superseded runtime tool class is no longer offered twice.** Discovery
  read every `SchemaTools` subclass out of `descendants`, where a class built
  at runtime stays until it is collected, so rebuilding a model's tools
  accumulated stale duplicates. Runtime-built classes are now read from the
  registry only. (#441)
- **A persisted model selection re-runs under the provider it ran under.**
  `Evals::ModelSpec.parse_all` re-parsed a round-tripped spec from its label,
  so `anthropic/claude-sonnet-4.5` run through OpenRouter came back as
  Anthropic's own `claude-sonnet-4.5` as soon as that provider's gem was
  installed — and the re-run failed for want of an Anthropic credential. A
  hash naming both `provider` and `model` is now rebuilt as it was; a bare
  label is still parsed. The dashboard's "re-run" of a saved selection is
  the path this fixes.
## [1.5.2] - 2026-09-11

Releases `activeagent` and `actionagent` 1.5.2 from one tag.

**1.5.1 was never tagged.** Its version bump reached `main`, but three PRs
that change `actionagent` merged alongside it, and that release deliberately
held `actionagent` at 1.5.0 — publishing it would have shipped the fix below
while leaving every dashboard change of this cycle unpublished, because
`release.yml` skips a version already on RubyGems. 1.5.2 supersedes it and
carries both gems. The 1.5.1 notes are kept below as the record of what that
bump contained.

### Added

- **Schema-derived agent tools.** `ActiveAgent::SchemaTools` turns an
  ActiveRecord model plus a declared boundary into a bounded, enumerable tool
  roster — `find_*`, `count_*`, `get_*` — with `filterable` and `returns`
  allowlists. An undeclared column is rejected rather than silently dropped:
  ignoring an unknown filter answers a broader question than was asked while
  still looking like success. Results are capped (25 default, 100 max) with a
  truncation marker the model can see. (#435)

- **Host tools reach the dashboard.** `ActionAgent.schema_tools` offers each
  generated tool beside `AgentToolbox`'s built-ins: individually selectable in
  the agent editor, dispatched by name at execution, and nameable in an
  evaluation's `tools:` expectation. Previously a declared schema tool was
  invisible — `definitions_for` returned nothing, the model received no
  schemas and invented tool names in prose while the run scored 0.0 for what
  looked like a model failure. (#435, closes #438)

- **Tools are discovered, not declared twice.** Leave `schema_tools` unset and
  every subclass under `schema_tools_path` (`app/agent_tools`) is offered.
  Adding a tool is adding a file. Anonymous classes are excluded from
  discovery: a runtime-built class cannot supersede itself, so it would
  accumulate one per reload. (#435, refs #440)

- **`scope_by_policy`** resolves a model's policy by name —
  `Reservation` → `ReservationPolicy::Scope` — instead of hand-writing the
  block. Opt-in, because silently scoping a class that declared none would
  change what an existing tool returns; a missing policy raises at declaration
  rather than quietly reading the whole table. (#435)

- **A model's agent starts with that model's tools.** `ReservationAgent` is
  seeded from `ReservationTools` on create. A default, never a restriction:
  any agent may enable any tool, and an explicit selection — including a
  deliberate empty one — is never overwritten. (#435)

### Fixed

- **MCP tool-discovery failures are reported instead of running tool-less and
  silent.** `MCPToolDispatcher#tool_definitions` rescued a failed `tools/list`
  to `[]`, so a server that 401s and one that legitimately serves no tools
  were indistinguishable: the agent ran without tools, the model fabricated,
  and the report offered prompt advice for what was a transport failure.
  `discovery_errors` now names the server, its URL and the underlying error,
  and `all_servers_failed?` lets a caller fail loudly rather than grade an
  invented answer. (#434, closes #425)

- **Nil VCR filters no longer flake replays**, and the MCP plural is spelled
  correctly. (#436)

## [1.5.1] - 2026-09-11 [UNRELEASED — superseded by 1.5.2]

Bumped `activeagent` to 1.5.1 and held `actionagent` at 1.5.0. Never tagged;
its contents ship in 1.5.2.

### Fixed

- **A spec hash names its model rather than reaching the provider as an
  inspected Hash.** `Evals::ModelSpec.parse_all` called `to_s` on each value,
  so a Hash travelled as the model ID and the provider answered
  `{"label" => "openrouter/openai/gpt-4o-mini", ...} is not a valid model ID`
  — every scenario of the run failing before it reached the model. A caller
  passing a plain string was unaffected, which is why a single run worked
  while a whole suite failed. The path is reachable by design rather than by
  misuse: a run persists its models as `specs.map(&:to_h)`, so re-running that
  selection hands the hashes back. `parse_all` now reads a hash's `label`,
  then its `model`, and leaves strings alone.

## [1.5.0] - 2026-09-10

Releases `activeagent` 1.5.0 and `actionagent` 1.5.0 from one tag.

`actionagent` goes from 1.3.0 to 1.5.0, skipping 1.4: the two gems are
released together from this repository and from one tag, and carrying one
version number across both is less confusing than explaining which
dashboard version pairs with which framework. `actionagent` 1.4 does not
exist and never will. The engine's floor on the framework
(`activeagent >= 1.4`) is unchanged and still correct.

### Added

- **`ActiveAgent::Evals::Publisher` delivers a finished report to a
  collector.** A run that already happened — in CI, in a host app's own
  runtime, anywhere the evaluation core runs — can be sent to an
  ActiveAgents-compatible collector without replaying the agent:
  `Publisher.new(api_key:, endpoint:).call(report:, run_id:, source:,
  agent_name:, suite:)` posts a version-1 envelope wrapping `Report#to_h`
  (or the saved JSON hash of an earlier run) and returns the collector's
  receipt. Delivery is synchronous, requires HTTPS outside loopback, does
  not follow a redirect carrying the bearer credential, caps a request at
  2 MiB, and raises `Publisher::Error` on anything but a receipt naming the
  same `run_id` — so a retry with that same `run_id` and the saved report
  re-delivers rather than re-runs. Publication is strictly opt-in and
  happens only where an application writes the call: no configuration flag,
  no callback, no default credential, and `api_key:` supplied explicitly at
  the call site. That is deliberate, because the payload is the report
  itself — every scenario's prompt, the agent's answers, and the tool calls
  and their results — and whether that may leave the application is the
  application's decision to make. Installing the gem sends nothing
  anywhere. `docs/evals/publication.md` documents the envelope, the receipt
  and the retry rules. (#414)

- **`Runner` takes `around_evaluation:` and `require_judge_scores:`.**
  `around_evaluation:` is called with `(scenario, spec)` and a block, and
  wraps the whole evaluation — the replay, the scoring, the judge calls
  behind a recommendation — so a host can establish one trace context
  across all of it and correlate a replay with the judging it triggered. It
  must return the block's result; `on_result` runs after it returns, an
  error it raises propagates to the caller, and `#evaluate` called directly
  bypasses it, for a host doing its own scheduling. `require_judge_scores:`
  (default `false`) settles what an unusable judge means. A judge that
  raises or answers unscorably is skipped, and the scenario is then decided
  on its rule scores alone — which reads as "the agent passed" when the
  truth is "nobody graded the answer". Set it, and an otherwise passing
  result whose `task_completion` or declared `llm_judge` criterion has no
  usable score fails instead, with the new `judge_unavailable` fault naming
  the unscored criteria and pointing at the judge's credentials, model and
  JSON reply. A run with no judged criteria is unaffected. (#414)

- **A grouped suite imports as YAML or JSON, whole.** `ScenarioParser` read
  a pasted list or a JSON array of scenarios; it now also reads the grouped
  document `Suite` loads — `groups:` with per-group keys and display names,
  scenarios carrying `key`, `prompt`, `notes`, `expect` and
  `production_only` — from YAML or JSON, keeping every part of it.
  `ScenarioParser.parse` and `.scenarios` gain `include_production_only:`,
  which defaults to `true` to match `Suite`. The dashboard defaults it the
  other way: post the document as `scenarios_text` and the production-only
  questions stay out unless `include_production_only` is sent alongside it,
  because those prompts run against a live agent. The choice is made at
  import — the engine stores the scenarios it selected, not the source
  document — so changing it means importing the document again. (#414)

- **`actionagent`: `ActionAgent.scenario_evaluation_adapter_resolver`.** A
  host application with its own agent runtime can now run an evaluation
  itself while keeping the dashboard's catalog, selection, jobs, result
  persistence and report pages. The resolver is called with the persisted
  evaluation and returns `nil` for the engine's normal `Agent#test_execute`
  path, or a callable — `evaluation:`, `owner:`, `scenarios:`, `models:`,
  `on_result:` — that runs the host's own agent and judge, yields every
  result as it lands, and returns an `ActiveAgent::Evals::Report`. The
  engine holds it to that contract: anything other than a `Report`, or a
  report that omits or duplicates one of the selected scenario × model
  pairs, fails the run rather than completing it with rows missing, and an
  exception leaves the results already written in place. Dashboard
  authentication, execution enablement and the host's execution quota still
  apply. (#414)

- **`actionagent`: the Run Agent page is a conversation workbench.** Testing
  an agent used to mean one prompt in, one output out, with no way to see —
  or shape — what the model was given. The page now works the way a user
  would work the agent: it pins a persisted conversation (a solid_agent
  context) and every run sends that conversation's user and assistant turns
  ahead of the new message, so follow-up questions actually follow up. The
  context is editable in place — edit or delete a turn, seed a user or
  assistant message without running, start a new conversation — and every
  run is a fresh `AgentRun` with its own trace, so Traces and Interactions
  see exactly what the model saw. Files attach to a message and ride along
  through Active Storage (`AgentRun has_many_attached :attachments`, guarded
  for hosts without it): images reach the model as vision input, PDFs as
  documents, and text-like files (CSV, Markdown, JSON, plain text) are
  inlined into the message; the persisted user message keeps an attachment
  manifest so the conversation shows thumbnails afterwards. Assistant replies
  can render **generative UI** — cards, stats, tables, charts, lists,
  progress, forms, choice buttons, images, callouts and code — from a fenced
  ```` ```ui ```` JSON block in prose, a JSON reply whose top level is
  `ui`/`blocks`, or the new `render_ui` tool (enable the **Generative UI**
  tool on the agent). Forms and choices post their answer back into the
  conversation as the next user message. New engine API: `GET/POST
  /api/agents/:id/conversations`, message create/update/delete under
  `/api/interactions/:id/messages`, multipart `POST /api/agents/:id/execute`
  with `attachments[]` and `params[context_id]`, and attachment metadata on
  run and message JSON. The reference host (`test/dummy`) gained the Active
  Storage tables so the attachment path is exercised by the engine's tests.
  Two notes for anyone driving that API directly: `execute`/`test` now answer
  422 unless the request carries a prompt or a file, and per-run overrides in
  `params` can no longer name `attachments` or `action` — those stay the
  controller's to set. Model-supplied images in generative UI load on sight
  only when they are inline data or this app's own URL; any other host is
  offered as a click-to-load, since fetching one tells that host whatever the
  model put in the URL.

### Fixed

- **A scenario passes only if it completed the task.** A scenario's verdict
  was the mean of everything scored for it, and the judge's
  `task_completion` grade was one number in that mean: an answer that
  called the expected tool and contained the expected string could carry a
  task grade of 0.2 to a mean of 0.73 and pass at the default threshold of
  0.7. `task_completion` is a gate now — it has to reach `threshold` on its
  own, and no number of passing tool and content checks can lift it — and
  the fault names the number that failed: "Task completion scored 0.2
  against a pass threshold of 0.7". An evaluation that configures its own
  `llm_judge` criteria rather than relying on the implicit grade — which is
  what the dashboard does — is gated the same way, on the mean of those
  grades, so one soft dimension among strong ones still passes while an
  answer the judge marked down cannot be carried by its mechanics. A
  scenario the judge could not grade at all is unchanged, still falling
  back to the rule scores. `score` and `avg_score` still mean the aggregate
  they always did, and each model's
  summary gains `avg_task_completion` so the judge's grade reads separately
  from it. **This can turn a suite that passed on 1.4.0 red; see the note
  on upgrading below.** (#414)

- **A judge's score is read as a JSON number.** The score was pulled out of
  the judge's reply by regular expression, matching the first run of digits
  after `"score":`. It read `{"score": 9e-2}` — 0.09 — as 9, clamped to a
  perfect 1.0; it read the string `{"score": "0.9"}` and the truncated
  `{"score": 0.9oops}` as a confident 0.9 rather than as unusable. The
  score now comes from the parsed JSON object and has to be a finite
  number, so exponent notation is read as written and a string, a boolean,
  `null`, `NaN` or `1e999` is unscorable — which the runner already knows
  how to handle. Fenced ```` ```json ```` replies still parse. The
  dashboard's generation-sampling evaluations score through the engine's own
  judge rather than the framework's, and read a score by the same rule now,
  so the two halves of the dashboard no longer disagree about the same
  reply. (#414)

- **A judge that answers with the wrong types cannot put junk in the fix
  list.** `suggested_tool` and `instruction_change` were coerced rather
  than checked, so a reply of `"suggested_tool": {"name": true}` added a
  tool literally named `true` to the report's suggested tools, and
  `"instruction_change": ["invalid"]` became a fix card asking someone to
  add `["invalid"]` to the agent's instructions. Both fields must now be
  nonempty strings and are dropped when they are not, so a malformed reply
  loses only the malformed part: the judge's recommendation still reaches
  the result, the report and every rendering of it. (#414)

- **A grouped suite pasted into the dashboard keeps its keys and
  expectations.** Only a pasted list or JSON was recognised, so a YAML suite
  went to the line parser and was read as prose: a document describing three
  scenarios became eighteen, with prompts like `tools: [lookup_order]` and
  `production_only: true`, groups named `expect`, generated keys in place of
  the document's own, and every expectation dropped — a suite that looked
  imported and scored nothing real. Such a document is now parsed as the
  suite it is, and one that is not valid, or a selection that matches no
  scenarios, returns an import error (`ScenarioParser::ParseError`, HTTP
  422) instead of a suite of nonsense or a sampling evaluation nobody asked
  for. (#414)

- **`actionagent`: run and result metadata survive persistence.** A run
  rebuilt from the database was rebuilt without it: `Report#metadata` came
  back holding only the four keys the engine writes itself, and each
  result's replay metadata was gone entirely, so a host's own run and result
  IDs, response trace IDs and judge trace IDs did not survive the round trip
  and its reports could not be joined to its telemetry. Run metadata is now
  kept in `scores["_metadata"]` and per-result metadata in
  `diagnosis["_replay_metadata"]`, restored by `EvaluationRun#to_report` and
  served as `metadata` on result JSON. Both are reserved storage keys that
  the public diagnosis excludes, so nothing migrates and `diagnosis` still
  means what it did. (#414)

- **`actionagent`: refreshing a catalog does not rewrite what an earlier run
  asked.** A saved run rendered its scenarios from the catalog rows as they
  are now, so rewording a question, retagging its group or changing its
  expectations silently rewrote history — last month's report showed this
  month's prompt above last month's answers, and judged them against
  expectations that were not in force when they were given. Each result now
  records the scenario it was actually evaluated against in
  `diagnosis["_scenario_snapshot"]`, and the report, the API and the
  scenario matrix read that snapshot, in the order the run itself used, with
  the dashboard noting on a scenario whose catalog entry has since changed
  that re-running uses the current one. A run records its judge the same
  way, in `scores["_judge_label"]`: `Report#to_h` and `#to_markdown` now
  name the judge a rebuilt run was given instead of reporting "No judge" for
  every run reconstructed from the database. Results saved before this
  release carry no snapshot and still render from the current catalog, and a
  link to a saved report (`?evaluation=:id&run=:run_id`) now opens its
  evaluation even when it is no longer on the first page of the index.
  (#414)

- **`actionagent`: an observed agent cannot be made executable.** An agent
  discovered from telemetry has no configuration to run, and `execute` and
  `test` refused one — but `update` and `restore` did not, so an observed
  record could be flipped to `active`, given instructions and then run; and
  a run queued against an agent that became observed afterwards still
  reached a provider when its job came up. The refusal now covers `update`
  and `restore` as well, and it is enforced under the API rather than only
  in front of it: `Agent#execute`, `#test_execute` and
  `AgentExecutionService#call` raise
  `ActionAgent::Agent::ObservedAgentError`, so that queued job fails its run
  without a provider call or a trace. Duplicating the agent still gives you
  an executable copy, and an evaluation whose host explicitly resolves an
  adapter for it remains the one path that replays an observed agent's
  scenarios. (#414)

- **The OpenAI Responses API keeps images and documents on a message with a
  role.** `{ role: "user", text: "…", image: "…" }` — the shorthand the Chat
  API and Anthropic transforms accept, and the only provider-neutral way to
  send history followed by a multimodal turn — lost its `image:` or
  `document:` on the provider the framework defaults to, because the
  Responses transform kept only `content` from a role-bearing hash. It now
  builds `input_text` / `input_image` / `input_file` parts for it, and a
  media-only `{ role: "user", image: "…" }` becomes a message with one part.
  The shorthand keys always come off the message, so a hash that carries
  `content` *and* `image:` no longer sends `image` as an unknown parameter,
  and a blank `image:`/`document:` contributes no part rather than an empty
  one. A nil `document:` alongside a role was the unknown-parameter case; the
  crash needed the role-less `{ document: nil }` inside a content array, which
  called `start_with?` on nil.

- **`actionagent`: a dashboard run's trace is attributed to the agent that
  ran it.** Every locally stored run used to register an "observed" twin of
  its own agent, because a run's class and action match no authored record.
  The service that ran the agent now names it when it records the trace.
  It is named by that caller and never read from the payload: resource
  attributes are whatever the reporter sent, and single-tenant ingest is
  unauthenticated unless `ActionAgent.ingest_api_key` is set, so an id taken
  from there would let any reporter bind its traces to any authored agent by
  guessing a primary key. A host that swaps in its own `trace_model` should
  add the `agent:` keyword to its `create_from_payload`; without it the
  dashboard logs the error and records no trace for its own runs. (#405)

- **`actionagent`: an observed agent's history cannot be authored.** The
  runner's conversation workbench writes an agent's history without running
  it, and those two endpoints — starting a conversation, and seeding, editing
  or deleting a turn — did not answer to the read-only rule execution does.
  A turn typed into a telemetry mirror would be a fabrication attributed to
  an agent whose whole point is that it only reports what really happened.
  Both refuse an observed agent now, with the same message and status
  `execute` gives. Reading that history is unchanged. (#405)

### Note on upgrading from 1.4.0

A scenario suite that passed on 1.4.0 can fail on this release with nothing
about your agent, your models or your suite having changed. Nothing has
regressed: the numbers those runs passed on were wrong, and this release
stops averaging them away.

A scenario's score was the mean of every criterion scored for it, and the
judge's `task_completion` grade — its answer to "did this actually do what
was asked" — was one term in that mean, alongside the rule checks. An answer
that called the expected tool, called it successfully, and contained the
expected string scored 1.0, 1.0 and 0.2 for a mean of 0.73, and passed at
the default threshold of 0.7: the mechanics carried the answer. That is the
wrong answer to the question an evaluation exists to ask. The agent called
`lookup_order`, said "ABC-123", and still never told the customer where the
order was — and the suite went green.

From this release `task_completion` has to clear `threshold` on its own.
Expect the first run after upgrading to show fewer passes than the run
before it, concentrated in the scenarios whose answers were thin, evasive or
wrong while their mechanics were right. Each of those now carries the
`low_quality` fault with a summary naming the grade that failed — "Task
completion scored 0.2 against a pass threshold of 0.7" — and the judge's
recommendation for it, and each model's summary reports
`avg_task_completion` beside `avg_score`, so a drop in pass rate can be read
against the grade that caused it. Nothing else about scoring moved: a
scenario the judge could not grade still falls back to its rule scores
unless you opt into `require_judge_scores: true`, and a suite meant to be
scored on mechanics alone can run without a judge or at a lower `threshold`.
Read that first run as a new baseline rather than a regression — it is
measuring something the runs before it were not.

## [1.4.0] - 2026-09-09

Releases `activeagent` 1.4.0 and `actionagent` 1.3.0 from one tag.

### Added

- **`ActiveAgent::Evals`, the evaluation core, in the framework.** Pasted-list
  and YAML suite parsing, model resolution, rule and expectation scoring, the
  fault taxonomy with its recommendations, the optional judge, and the
  per-model report live in `lib/active_agent/evals`, loadable on their own
  with `require "active_agent/evals"`. Any app can replay a list of tasks
  across models against its own agent through one `replay` callable and get
  the same faults, recommendations and verdict the dashboard shows;
  `actionagent` keeps only what the dashboard adds — persistence, the job,
  the API and the UI.
- **Scenario evaluations in the dashboard.** An evaluation can now carry a
  suite of scenarios — a pasted list of user messages, grouped with
  `# Heading` lines and annotated with the tool each should call — and a run
  replays every selected scenario through the agent once per candidate model
  (`compare_models`, or a per-run `models` selection) instead of sampling
  recorded generations. Each scenario × model result records the answer, the
  tools called, its score, and, when it falls short, one fault
  (`run_error`, `tool_error`, `missing_capability`,
  `expected_tool_not_called`, `forbidden_content`, `missing_content`,
  `low_quality`) with a recommendation; a configured judge model refines the
  recommendation with the tool to add or the instruction to change. Runs can
  be narrowed to a group or to single scenarios, and the run summary ranks
  the models by pass rate with a verdict. New tables
  `evaluation_scenarios` and `evaluation_scenario_results` ship in
  `create_active_agent_evaluation_scenarios`, which
  `rails generate action_agent:install` emits for new and existing installs.
- **`ActionAgent.mcp_catalog`.** A host app registers the MCP servers it
  serves or connects itself — `[{ key:, name:, tool_hints: [...] }, …]` —
  and they join the built-in catalog: listed in the MCP Services view, with
  telemetry traffic for their bare tool names attributed to them.
  `MCPCatalog.keys` lists built-ins and registrations together;
  `MCPCatalog::BY_KEY` still holds the built-ins alone.
- **Suite results rebuilt around what to do next.** An expanded scenario
  suite used to be a summary and a matrix; it now opens on the three
  questions a run is actually asked. **Runs** numbers every run of the suite
  from the oldest and scores it against the one before — `+3 passed vs #7`,
  or `partial run` when the two covered different scenarios or models and the
  numbers do not compare — so progress is legible without reading two runs
  side by side; selecting an older run re-derives the models, the fix list,
  the matrix and every drill-down, and the collapsed header keeps reporting
  the latest. **Models** marks the best candidate with an info-toned
  `judge's pick` badge and the verdict that justifies it, rather than a green
  *winner* — losing a comparison by one scenario is not a failing grade.
  **What to fix** turns each fault into a card with the tools involved
  (deduplicated to one chip each), the MCP server that serves them, whether
  this agent has it enabled, and a button that deep-links to MCP Services,
  Tools or the agent's instructions: the fix, not just the finding. The
  scenario × model matrix shows the tools each model actually called against
  the tools the scenario expected, coloured by whether they match, and a row
  opens onto every model's answer, timing, cost and diagnosis.
- **The evaluation report is a designed page.** `Report#to_html(theme:)`
  renders a run on the dashboard's design system — stat tiles, a panel per
  model with the judge's pick and verdict, the what-to-fix cards, the
  scenario × model matrix and a disclosure per scenario — still one
  self-contained file with inline styles and no external assets, so it
  archives next to a CI run. `theme:` pins `"light"` or `"dark"`; without it
  the page follows the viewer's `prefers-color-scheme`, and the dashboard
  passes its own theme through when it frames the report at
  `/api/evaluations/:id/runs/:run_id/report`. The new `Report#fix_items`
  builds the what-to-fix list — faults grouped with the tools each implicates
  and the action that addresses it — for the page, the engine's API and any
  app that wants the backlog as JSON; `tool_resolver:`, `agent_name:` and
  `links:` on `Report.new` let a host name the MCP server behind a tool, the
  agent, and the routes an action should point at, so a CI job gets the same
  cards the dashboard shows.
- **An APM-style service overview on the Metrics page.** The page answered
  "how much traffic in the last 24 hours"; it now answers "is this healthy
  right now, and since when". A `1h` / `24h` / `7d` range fixes the bucket
  size the whole page is drawn at (60 × 1 min, 96 × 15 min, 84 × 2 h); five
  golden signals — requests, latency, error rate, tokens, cost — carry a
  sparkline and a delta against the period just before the window; six panels
  plot requests stacked by agent, latency percentiles, errors by class,
  tokens, spend and tool calls, with markers for the agent versions deployed
  inside the window and for an error spike when one stands out; and a rail
  ranks the agents, models, slowest actions, tools and error classes behind
  them. Filtering to an agent — from the select, or by clicking its rail
  row — narrows every one of those together. `GET /api/metrics` gains
  `range` and `agent` params and the keys that feed it (`totals`, `deltas`,
  `series`, `agents`, `models`, `actions`, `tools`, `errors_by_type`,
  `markers`) from the new `ActionAgent::MetricsReport`: one pass over the
  window, with bucketing, nearest-rank percentiles and error classification
  done in Ruby so PostgreSQL and SQLite report the same numbers. Every
  earlier key and param still means what it did.
- **A design token layer under the dashboard.** Colors, fonts and the type
  scale live in `actionagent/frontend/tokens.css` as CSS variables scoped to
  the mounted dashboard (`.aa-dashboard`, with the dark palette under
  `.theme-dark`), and the views draw from a set of shared primitives —
  badges, chips, panels, cards, pass bars, stat tiles, segmented controls —
  instead of each restating the same hex codes and paddings. Dark mode is
  then one class rather than a conditional at every call site, and a host
  app's own stylesheet cannot bleed into the engine's. The framework carries
  the same values in `ActiveAgent::Evals::DesignTokens` so the standalone
  HTML report matches the dashboard it came from, with a test that fails when
  the two drift apart.

- **RubyLLM backend pinning via `platform:`.** RubyLLM resolves which of its
  providers serves a request from the model ID, and a model served by more
  than one — `gemini-2.5-flash` exists on both the Gemini API and Vertex
  AI — lands on whichever RubyLLM's registry prefers, with no way to say
  otherwise from ActiveAgent. The new `platform:` option
  (`generate_with :ruby_llm, model: "gemini-2.5-flash", platform: :vertexai`)
  forwards to RubyLLM's `provider:` and pins the backend, for embeddings as
  well as prompts. It is not named `provider:` because a provider reference
  is already the first argument to `generate_with`. Omitting it keeps
  model-based routing unchanged. (#373)

### Fixed

- **A run report is readable in the dashboard.** The report was framed at a
  fixed viewport height, so everything past the first screen — including
  every fix item — sat behind a nested scrollbar. The frame is sized to the
  report's own content, and a fix action targets the top window so it
  navigates the dashboard instead of loading it into the frame. (#410, #411)

- **Provider credentials store on a host that skipped `db:encryption:init`.**
  Encryption keys derived from `secret_key_base` were installed after Rails
  had already configured `ActiveRecord::Encryption`, so the config read back
  correct while every credential write raised `Errors::Configuration` — in
  the dashboard, the Settings API Keys tab failed to render and provider
  keys failed to save. (#412)

- **`service: "RubyLLM"` loads when the ruby_llm railtie has run.** The
  ruby_llm gem registers `RubyLLM` as an inflector acronym in Rails apps,
  which turns `"RubyLLM".underscore` into `rubyllm` — so provider loading
  required a nonexistent `rubyllm_provider.rb` and failed with
  `cannot load such file`. An alias file now covers that require path, the
  same fix `openai_provider.rb` applies for `OpenAI`. (#371, fixed in #372
  by @aoki-ryusei; regression tests in #374)

## [1.3.1] - 2026-08-19

### Fixed

- **Traces record the user turn an agent renders from its template.** An
  agent written the idiomatic way — `instructions:` plus `locals:`, with the
  user message in the action's ERB — passed no `messages:`, so the
  instrumentation had nothing to serialize and `prompt.input.messages` was
  absent from its traces. The system prompt and the completion were both
  captured, which made the gap easy to miss: a trace looked populated while
  the half an evaluation scores, what the model was actually asked, was
  missing. The instrumentation now falls back to the rendered parameters when
  no explicit messages exist.

### Note on the 1.3.0 gem

`activeagent 1.3.0` was published from a tree that already carried the fix
above, so the released gem did not match the `v1.3.0` tag — the tag's source
would not reproduce it. This release contains no change relative to that
published gem; it exists so that the tag, `main` and the published gem agree
again. Upgrading from 1.3.0 is optional and changes no behaviour.

## [1.3.0] - 2026-08-18

### Added

- **Agent-as-tool delegation.** A tool is a Ruby method the model can call; a
  delegation is another agent it can call. The callee keeps its own
  instructions, templates, model and budget, so a specialist agent stays
  specialist and the generalist orchestrating it never inherits its prompt.
  Declared with `delegation :action, description:` on the sub-agent, with a
  JSON Schema for the inputs and an optional `returns` schema that becomes the
  sub-agent's response format. See `docs/actions/delegation.md`.

### Fixed

- **Streamed generations report their token usage.** A request with
  `stream: true` recorded zero input and output tokens, and so zero cost and
  no context-pressure estimate downstream — dashboards showed `Tokens 0` and
  `$0.00` beside a run that had plainly called the API. Three things had to
  hold at once for the usage to survive, and none did: the streaming path
  returns `nil` rather than a response body to read usage from; Chat
  Completions only emits its usage chunk when the request sets
  `stream_options: {include_usage: true}`, which was never sent; and that
  chunk arrives *after* `content.done`, where the response was already being
  built. Completion now defers until the stream drains, and the usage chunk
  is recorded on the way past. A provider hook (`api_stream_usage_parameters`,
  empty by default) keeps providers that report unconditionally — or not at
  all — unaffected.

  Also fixed a silent conversion failure behind the same symptom:
  `Usage.from_provider_usage` early-returns on anything that is not a Hash,
  and the stainless gems hand back model objects, so usage was dropped even
  when it did arrive.

### Note on the 1.2.0 tag

The `v1.2.0` tag had been moved to a commit later than the one published as
`activeagent 1.2.0`, so the tag and the gem disagreed. It has been repointed
to the commit that actually produced the release. If you fetched the tag
between 2026-08-14 and 2026-08-18, re-fetch with `git fetch --tags --force`.

## [1.2.2] - 2026-08-14

### Fixed

- **`actionagent`: every engine constant resolves under a host's
  inflections.** 1.2.1 scoped its autoloader override to the basename `api`,
  which covered the controllers under `app/controllers/action_agent/api` and
  nothing else. Seven files camelize differently once a host registers an
  acronym — `mcp_catalog.rb`, `mcp_recording_middleware.rb`,
  `playwright_mcp_client.rb`, `api_key.rb`, and the `api_keys`, `mcp` and
  `mcp_servers` controllers — and each raised `Zeitwerk::NameError` on first
  reference. In a host declaring `inflect.acronym "MCP"` the **Tools view was
  unreachable** (`uninitialized constant
  ActionAgent::ToolDiscovery::McpCatalog`), as were the MCP endpoints and
  anything touching an API key.

  Every path under the engine now camelizes with Zeitwerk's default
  inflector, ignoring the host's acronyms, scoped by path so the host's own
  constants keep their spelling. The router half generalizes with it: an
  all-caps run in a missing constant is retried in the relaxed spelling
  (`API` → `Api`, `MCPServersController` → `McpServersController`) rather
  than aliasing each pair by hand.

## [1.2.1] - 2026-08-14

### Fixed

- **`actionagent`: the install migrations now run on MySQL.** Both templates
  already chose the JSON column type per adapter, but kept `default: []` /
  `default: {}` for every adapter, and MySQL rejects a default on a JSON
  column outright — so `rails g action_agent:install && rails db:migrate`
  aborted mid-`create_table` on any MySQL host. The default (and the paired
  `null: false`, which without it would reject the inserts the default
  existed to satisfy) is now PostgreSQL-only. Every JSON column is read
  through `Array(...)` / `|| {}`, so a NULL reads as the empty value.
- **`actionagent`: the mount works in a host that declares
  `inflect.acronym "API"`.** An engine's files are autoloaded under the
  host's inflections, so such a host made Zeitwerk expect
  `ActionAgent::API::TracesController` from a file defining
  `ActionAgent::Api::TracesController`, and every request to the mount
  raised `Zeitwerk::NameError`. Rails separately camelizes a route's stored
  controller path with the host's global inflections, which no engine-level
  setting scopes. The autoloader is now pinned to `Api` for this engine's
  own path, and the namespace answers to `API` as well.

## [1.2.0] - 2026-08-14

### ⚠️ The dashboard has moved to its own gem

The dashboard engine that shipped inside `activeagent` is now a separate
gem, **`actionagent`**. Nothing is gone — the dashboard is the same
dashboard, and it gained a great deal in this release — but it comes from a
different gem now. `activeagent` is the framework alone: it no longer
defines `ActiveAgent::Dashboard`, and no longer pulls Active Record into
apps that do not use it.

**If you mount the dashboard, add the new gem in the same change that
upgrades `activeagent`:**

```ruby
gem "activeagent", "~> 1.2"
gem "actionagent", "~> 1.2"   # required if you mount the dashboard
```

This is a minor version, so a `~> 1.0` or `~> 1.1` constraint **will** pick
it up on the next `bundle update`. If you mount the dashboard and do not add
`actionagent` at the same time, the app fails at boot with
`NameError: uninitialized constant ActiveAgent::Dashboard`, raised by your
own initializer or by the `mount ActiveAgent::Dashboard::Engine` line in
`config/routes.rb`. Adding the gem is the whole fix — your existing
configuration keeps working through the compatibility shims below.

If you do not mount the dashboard, there is nothing to do: the framework API
is unchanged, and the gem is 95% smaller.

With `actionagent` installed, the old constants keep resolving through
`ActionAgent::Compatibility` with a deprecation warning:

- `ActiveAgent::Dashboard` → `ActionAgent`
- `ActiveAgent::TelemetryTrace` → `ActionAgent::TelemetryTrace`
- `ActiveAgent::ProcessTelemetryTracesJob` → `ActionAgent::ProcessTelemetryTracesJob`

That last one matters beyond tidiness: Active Job serializes the class name
into the queue payload, so jobs enqueued before the upgrade still resolve
after it.

Other changes for mounted installs:

- **The server-rendered traces console moves from `/traces` to
  `/console/traces`.** `/traces` is now the React traces view — the same
  data, with more of it.
- **The mount is authenticated everywhere but development and test.** The
  sandbox API, the session-recording capture endpoints and the template
  endpoints previously allowed anonymous access; they no longer do. The
  `GET /api/session_recordings/demo` endpoint is removed.
- **`current_user_method` / `current_account_method` are superseded by
  `current_user_resolver` / `current_account_resolver`.** The engine's
  controllers are their own base class, so a host app's `current_user`
  helper is not available to them.
- **An unresolved owner now scopes to nothing rather than to everything.**
  If you configure `user_class` or `account_class`, make sure the matching
  resolver actually returns a record, or the dashboard will show no data.
- Existing installs upgrading from the in-gem dashboard: re-run
  `rails generate action_agent:install`. It detects the migrations you
  already have and emits only what is missing.

## [1.1.0] - 2026-08-12

### Dashboard — self-hosted (enterprise) mount readiness

The engine can now be mounted in any Rails app as the self-hosted
observability surface (see `docs/framework/self-hosted-observability.md`):

- **One install generator**: the duplicate `active_agent:dashboard:install`
  variant that copied eight migrations (agents, sandboxes, recordings —
  tables for models with no shipped controllers or routes) is removed.
  The surviving generator installs the telemetry traces table only and
  gains `--skip_migrations` / `--skip_routes`; its initializer template now
  covers authentication, `ingest_api_key`, and multi-tenant options.
- **Canonical mount path is `/activeagents`** (generator, dummy app and
  docs updated). `Telemetry::Configuration#resolved_endpoint` now reports
  the ingest path for wherever the engine is actually mounted — any mount
  path, including `/` on a dedicated subdomain — instead of a hardcoded
  constant, falling back to `LOCAL_ENDPOINT_PATH` when it isn't mounted.
  Note this is informational: `local_storage` capture writes through the
  trace model without HTTP, and remote apps set `endpoint:` explicitly.
- **`TracesController` honors configuration**: index/metrics/time-series
  queries now go through `ActiveAgent::Dashboard.trace_model` (previously
  only `show` did) and are scoped with `for_account(current_owner)`, so a
  `trace_model_class` override and multi-tenant scoping apply everywhere.
- **Single-tenant ingest auth**: new `config.ingest_api_key` requires a
  matching Bearer token on `POST <mount>/api/traces` when set. The
  telemetry reporter and ruby_llm_telemetry already send their `api_key`
  as a Bearer header, so remote apps need no changes.
- **Metrics page no longer 500s with data**: the per-agent stats table
  read a grouped SQL alias through a model method that expected per-trace
  token columns.
- **Mount detection is route-set based**: the ingest path is resolved by
  locating the mounted engine in the host's routes rather than assuming
  the default `active_agent_path` helper, so `mount ... => "/", as:
  :something_else` and constraint-wrapped (subdomain) mounts resolve
  correctly instead of silently falling back.
- Deprecated the never-consumed `base_controller_class` config attribute:
  it remains a no-op accessor with its historical default so existing
  initializers keep booting, and will be removed in the next major.

### Agent-as-tool delegation

Sub-agents are now a first-class primitive. A tool is a Ruby method your
model can call; a delegation is another agent your model can call — with
its own instructions, templates, model and budget.

- **`delegation :action, description:`** declares what a sub-agent exposes:
  a description for the calling model, a JSON Schema for its inputs (block
  DSL, a plain hash, or any class responding to `to_json_schema`), and
  optionally a `returns` schema. A declared `returns` becomes the
  sub-agent's `response_format`, and its answer is parsed and checked
  before the caller sees it.
- **`delegate_to AgentClass`** exposes those contracts to the calling model
  as tools, with `only:`/`except:`/`as:` for scoping and renaming,
  `params:` for forwarding, and `action:` for declaring a contract at the
  call site when you don't own the sub-agent. Per-action scoping via the
  `delegations:` prompt option.
- **Cost and latency budgets**: `max_calls`, `max_tokens`, `max_cost`,
  `max_duration` and a per-call `timeout`, set per delegation and/or
  agent-wide with `delegation_budget`. Exhausting one returns a structured
  result the model can act on (`on_exceeded: :stop`, the default) instead
  of raising mid-conversation; `:raise` is available. Budgets are scoped
  to a single generation, and spend is readable afterwards via
  `delegation_ledger`.
- **Swappable backends**: `backend: :ollama` or
  `backend: { provider: :anthropic, model: "claude-haiku-4-5" }` moves a
  delegation to different silicon without touching the sub-agent. Provider
  swaps rebuild provider configuration rather than merging over it, and
  template lookup still resolves to the original agent's views.
- **Cost registry**: `ActiveAgent::Delegation::Pricing.register` records
  token rates in USD per 1M tokens (no built-in price list, so `max_cost`
  never fires on stale numbers); rates can also be stated inline on a budget.
- **Instrumentation**: `delegate.active_agent` (agent, sub-agent, action,
  model, duration, usage, cost, ledger) and
  `delegation_refused.active_agent` (violated limit).
- **New docs** (`docs/actions/delegation.md`) with a worked support-triage
  example, plus test coverage in `test/features/delegation_test.rb` and
  `test/docs/actions/delegation_examples_test.rb`.

### Dashboard & Telemetry — dev console readiness

The dashboard engine — Active Agent's local dev console — now works out of
the box (production observability is the hosted platform product):

- **Engine load paths fixed**: `Engine.find_root` now points at the
  dashboard directory, so `ActiveAgent::TelemetryTrace`,
  `ProcessTelemetryTracesJob`, the API controller, views and engine routes
  are auto-discovered in host apps (previously they required manual
  `require`s). The engine is also required eagerly with Rails, since
  engines defined lazily miss initializer collection.
- **Routes now match shipped controllers**: the engine exposes traces,
  metrics and the ingest API (`<mount>/api/traces`); routes to
  never-shipped controllers (agents, sandboxes, templates, recordings,
  api/v1) were removed. Engine root renders the traces index.
- **`local_storage` telemetry mode fixed**: tracer payloads are
  symbol-keyed and were silently dropped by the string-keyed ingestion
  normalizer; the reporter now stringifies and honors
  `ActiveAgent::Dashboard.trace_model` overrides.
- **Token totals no longer double-count**: instrumentation mirrors LLM
  token usage onto the root span; `TelemetryTrace.create_from_payload`
  now counts child spans as the source of truth.
- **Span waterfall renders real offsets** (was pinned to 0ms), turbo-rails
  is now optional (previously 500s without it), layout route helpers fixed,
  `Agent.for_owner` scope added, synchronous ingest capped at 100
  traces/request.
- **New docs** (`docs/framework/dashboard.md`, README section) covering
  install, authentication (none by default — see docs), remote ingestion
  and multi-tenant mode; dashboard engine test suite added
  (`test/dashboard/`).

## [1.0.0] - 2025-11-21

Major refactor with breaking changes. Complete provider rewrite. New modular architecture.

**Requirements:** Ruby 3.1+, Rails 7.0+/8.0+/8.1+
## What's Changed
* Major Framework Refactor: ActiveAgent v1.0.0 by @sirwolfgang in https://github.com/activeagents/activeagent/pull/259
* Add API gem version testing and fix Anthropic 1.14.0 compatibility by @sirwolfgang in https://github.com/activeagents/activeagent/pull/265
* Fix version compatiblity issue for vitepress by @sirwolfgang in https://github.com/activeagents/activeagent/pull/266
* Add missing API Keys by @sirwolfgang in https://github.com/activeagents/activeagent/pull/267
* Fix website links by @sirwolfgang in https://github.com/activeagents/activeagent/pull/268
* chore: remove `standard` from dev dependencies by @okuramasafumi in https://github.com/activeagents/activeagent/pull/272
* Add thread safety tests by @sirwolfgang in https://github.com/activeagents/activeagent/pull/275
* Refactor: Leverage Native Gem Types Across All Providers by @sirwolfgang in https://github.com/activeagents/activeagent/pull/271
* Improved Usage Tracking by @sirwolfgang in https://github.com/activeagents/activeagent/pull/274

## New Contributors
* @okuramasafumi made their first contribution in https://github.com/activeagents/activeagent/pull/272

**Full Changelog**: https://github.com/activeagents/activeagent/compare/v0.6.3...v1.0.0

### Added

**Universal Tools Format**
```ruby
# Single format works across all providers (Anthropic, OpenAI, OpenRouter, Ollama, Mock)
tools: [{
  name: "get_weather",
  description: "Get current weather",
  parameters: {
    type: "object",
    properties: {
      location: { type: "string", description: "City and state" }
    },
    required: ["location"]
  }
}]

# Tool choice normalization
tool_choice: "auto"                   # Let model decide
tool_choice: "required"               # Force tool use
tool_choice: { name: "get_weather" }  # Force specific tool
```

Automatic conversion to provider-specific formats. Old formats still work (backward compatible).

**Model Context Protocol (MCP) Support**
```ruby
# Universal MCP format works across providers (Anthropic, OpenAI)
class MyAgent < ActiveAgent::Base
  generate_with :anthropic, model: "claude-haiku-4-5"

  def research
    prompt(
      message: "Research AI developments",
      mcps: [{
        name: "github",
        url: "https://api.githubcopilot.com/mcp/",
        authorization: ENV["GITHUB_MCP_TOKEN"]
      }]
    )
  end
end
```

- Common format: `{name: "server", url: "https://...", authorization: "token"}`
- Auto-converts to provider native formats
- Anthropic: Beta API support, up to 20 servers per request
- OpenAI: Responses API with pre-built connectors (Dropbox, Google Drive, etc.)
- Backwards compatible: accepts both `mcps` and `mcp_servers` parameters
- Comprehensive documentation with tested examples
- Full VCR test coverage with real MCP endpoints

### Changed

- Shared `ToolChoiceClearing` concern eliminates duplication across providers

### Breaking Changes

#### 1. Update Provider Gems

```ruby
# Gemfile - Remove unofficial gems
gem "ruby-openai"
gem "ruby-anthropic"

# Add official provider SDKs
gem "openai"      # Official OpenAI SDK
gem "anthropic"   # Official Anthropic SDK
```

Run `bundle install` after updating.

#### 2. Update Base Class

```ruby
# Before
class MyAgent < ActiveAgent::ActionPrompt::Base
end

# After
class MyAgent < ActiveAgent::Base
end
```

#### 3. Configure Providers

```ruby
# Before - options wrapped in options key
class MyAgent < ActiveAgent::Base
  def chat
    prompt(message: "Hello", options: { temperature: 0.7 })
  end
end

# After - options passed directly (at class or call level)
class MyAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini", temperature: 0.7

  def chat
    prompt("Hello")  # Uses class-level config
  end

  def chat_creative
    prompt("Hello", temperature: 1.0)  # Override per-call
  end
end
```

#### 4. Update Custom Providers (if any)

```ruby
# Before
module ActiveAgent::GenerationProvider
  class CustomProvider < Base
  end
end

# After
module ActiveAgent::Providers
  class CustomProvider < BaseProvider
  end
end
```

#### 5. Update Generator Commands

```bash
# Before
rails g active_agent MyAgent action

# After
rails g active_agent:agent MyAgent action
```

#### 6. Remove Framework Retry Config

```ruby
# Remove from config/initializers/activeagent.rb
ActiveAgent.configure do |config|
  config.retries = true
  config.retries_count = 5
end

# Use provider-specific settings in config/active_agent.yml
openai:
  service: "OpenAI"
  max_retries: 5
  timeout: 600.0
```

Template paths:
- `app/views/agents/{agent}/instructions.md` (no `.erb` extension by default for instructions)
- `app/views/agents/{agent}/{action}.md.erb`

### Added

**Mock Provider for Testing**
```ruby
class MyAgent < ActiveAgent::Base
  generate_with :mock
end

response = MyAgent.prompt("Test").generate_now
# Returns predictable responses without API calls
```

**Mixed Provider Support**
```ruby
class MyAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini"
  embed_with :anthropic, model: "claude-3-5-sonnet-20241022"
end
```

**Prompt Previews**
```ruby
preview = MyAgent.prompt("Hello").prompt_preview
# Shows instructions, messages, tools before execution
```

**Callback Lifecycle**
- `before_generation`, `after_generation`, `around_generation`
- `before_prompt`, `after_prompt`, `around_prompt`
- `before_embed`, `after_embed`, `around_embed`
- `on_stream_open`, `on_stream`, `on_stream_close`
- Rails-style callback control: `prepend_*`, `skip_*`, `append_*`

**Multi-Input Embeddings**
```ruby
response = MyAgent.embed(inputs: ["Text 1", "Text 2"]).embed_now
vectors = response.data.map { |d| d[:embedding] }
```

**Normalized Usage Statistics**
```ruby
response = MyAgent.prompt("Hello").generate_now

# Works across all providers
response.usage.input_tokens
response.usage.output_tokens
response.usage.total_tokens

# Provider-specific fields when available
response.usage.cached_tokens      # OpenAI, Anthropic
response.usage.reasoning_tokens   # OpenAI o1 models
response.usage.service_tier       # Anthropic
```

**Enhanced Instrumentation for APM Integration**
- Unified event structure: `prompt.active_agent` and `embed.active_agent` (top-level) plus `prompt.provider.active_agent` and `embed.provider.active_agent` (per-API-call)
- Event payloads include comprehensive data for monitoring tools (New Relic, DataDog, etc.):
  - Request parameters: `model`, `temperature`, `max_tokens`, `top_p`, `stream`, `message_count`, `has_tools`
  - Usage data: `input_tokens`, `output_tokens`, `total_tokens`, `cached_tokens`, `reasoning_tokens`, `audio_tokens`, `cache_creation_tokens` (critical for cost tracking)
  - Response metadata: `finish_reason`, `response_model`, `response_id`, `embedding_count`
- Top-level events report cumulative usage across all API calls in multi-turn conversations
- Provider-level events report per-call usage for granular tracking

**Multi-Turn Usage Tracking**
- `response.usage` now returns cumulative token counts across all API calls during tool calling
- New `response.usages` array contains individual usage objects from each API call
- `Usage` objects support addition: `usage1 + usage2` for combining statistics

**Provider Enhancements**
- OpenAI Responses API: `api: :responses` or `api: :chat`
- Anthropic JSON object mode with automatic extraction
- OpenRouter: quantization, provider preferences, web search
- Flexible naming: `:openai` or `:open_ai`, `:openrouter` or `:open_router`

**Rails 8.1 Support**

**Comprehensive Documentation**
- VitePress site at docs.activeagents.ai
- All examples tested and validated

### Changed

**Provider Architecture**
- Unified `BaseProvider` interface across all providers
- Retry logic moved to provider SDKs (automatic exponential backoff)
- Migrated to official SDKs: `openai` gem and `anthropic` gem
- Type-safe options with per-provider definitions

**Configuration**
- Options configurable at class level, instance level, or per-call
- Simplified parameter handling pattern

**Requirements**
- Ruby 3.1+ (previously 3.0+)

**Testing**
- Reorganized by feature and provider integration
- All documentation examples validated

### Fixed

**Providers**
- OpenAI streaming with functions/tools
- Ollama streaming support
- Anthropic tool choice modes (`any` and `tool`)
- OpenRouter model fallback and parameter naming
- Provider gem loading errors

**Framework**
- Streaming lifecycle with function/tool calls
- Multi-tool and multi-turn conversation handling
- Options mutation during generation
- Template rendering without blocks
- Schema generator key symbolization
- Rails 8.0 and 8.1 compatibility
- Usage extraction across OpenAI/Anthropic response formats

### Removed

**Namespaces**
- `ActiveAgent::ActionPrompt` → use `ActiveAgent::Base`
- `ActiveAgent::GenerationProvider` → use `ActiveAgent::Providers`

**Configuration**
- `ActiveAgent.configuration.retries` → use provider `max_retries`
- `ActiveAgent.configuration.retries_count` → use provider `max_retries`
- `ActiveAgent.configuration.retries_on` → handled by provider SDKs

**Modules**
- `ActiveAgent::QueuedGeneration` → `Queueing` concern
- `ActiveAgent::Rescuable` → `Rescue` concern
- `ActiveAgent::Sanitizers` → moved to concerns
- `ActiveAgent::PromptHelper` → moved to concerns

## [0.3.2] - 2025-04-15

### Added
- CI configuration for stable GitHub releases moving forward.
- Test coverage for core features: ActionPrompt rendering, tool calls, and embeddings.
- Enhance streaming to support tool calls during stream. Previously, streaming mode blocked tool call execution.
- Fix layout rendering bug when no block is passed and views now render correctly without requiring a block.

### Removed
- Generation Provider module and Action Prompt READMEs have been removed, but will be updated along with the main README in the next release.
