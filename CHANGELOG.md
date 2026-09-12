# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
