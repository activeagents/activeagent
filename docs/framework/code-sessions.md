# Code Sessions

A code session hands one of your dashboard agents to a *coding agent*
(Claude Code, Codex CLI, GitHub Copilot CLI, or an open-source agent such as
opencode, pi, Oh My Pi or aider) running in a sandbox, with a checkout of the
repository the agent lives in and a **brief** compiled from the agent's
evaluations and metrics. The brief says what the agent needs (tools, MCP
servers, instruction changes, credentials) and what it cannot do yet (faults,
failing scenarios, error rate, latency), so the coding agent works from
evidence instead of a vague "make it better", and you can read the same page
before you let it loose.

The sandbox is a [code-on-incus](https://github.com/mensfeld/code-on-incus)
container (`coi`) on an Incus host you operate. The engine ships an
in-memory `mock` backend so the feature works out of the box for development
and tests; nothing runs a coding agent until you register the real backend.

Open **Code Sessions** in the sidebar, or press *Hand to a coding agent* on
an evaluation run's fix list, which pre-selects that agent and run.

## The flow

1. **Evaluate.** Run a [scenario evaluation](/framework/dashboard#scenario-evaluations)
   against the agent. Its report knows which scenarios fail, with which
   fault, and what each fault calls for.
2. **Brief.** The New Code Session form compiles the brief from the newest
   complete scenario run (or the one you pick), the agent's tool and MCP
   configuration and the last 24 hours of telemetry, and shows it beside the
   form. The same brief is written to `/brief/BRIEF.md` inside the sandbox.
3. **Sandbox.** Creating the session provisions a container from a
   per-session `coi` profile, clones the repository into `/workspace/repo`
   (shallow, on the branch you named), and marks the session ready.
4. **Run.** *Run* sends the task to the coding agent headlessly and stores
   the transcript, exit code and, when the tool prints them, token counts.
   *Attach* copies a command you run in your own terminal to open a shell in
   the same container. With write access the default task asks the coding
   agent to commit on `code-session/<id>` and open a pull request; you review
   that PR like any other.
5. **Stop.** *Stop* or *Delete* shuts the container down and removes every
   file the session wrote on the host, the GitHub token included. Sessions
   expire on their own after `session_duration_minutes`.

## Operator setup

The `code_on_incus` backend needs a Linux host with Incus and the `coi` CLI:

1. Install [code-on-incus](https://github.com/mensfeld/code-on-incus) on the
   Incus host and run `coi build` once to build the container image (the
   coding tools are installed into that image; Copilot CLI and aider are not
   `coi` tools and have to be added to the image yourself).
2. Check the host with `coi health` and, later, read `coi audit` for what
   sessions did. `coi list --all` shows every container the engine has
   started, named `action-agent-<12 hex>`.
3. Point the engine at the host. When the Rails process runs on the Incus
   host itself, `binary: "coi"` is enough. When it does not, set
   `ssh_target` to a `user@host` the app can reach with key-based, non
   interactive SSH; every `coi` command is then prefixed with
   `ssh -o BatchMode=yes <target> --`, and the per-session state directory
   lives on the remote host. Restrict that SSH user to what `coi` needs.
4. Register the backend:

```ruby
# config/initializers/action_agent.rb
ActionAgent.configure do |config|
  config.code_session_backend = ENV.fetch("CODE_SESSION_BACKEND", "code_on_incus")
  config.code_on_incus.ssh_target = ENV["COI_SSH_TARGET"].presence
  config.code_on_incus.state_dir = ENV["COI_STATE_DIR"].presence
end
```

Every session gets its own `coi` profile that `inherits` the `hardened`
preset (change `base_profile` if your host defines another). The engine
never relies on `coi`'s profile search path: it writes the profile to the
session's state directory and sets `COI_CONFIG` to that file on each
invocation, which `coi` treats as trusted scope.

## Configuration

| Setting | Default | Meaning |
|---|---|---|
| `ActionAgent.code_session_backend` | `:mock` (`ENV["CODE_SESSION_BACKEND"]` overrides) | Backend used for new sessions. Built in: `mock`, `code_on_incus`. An unknown name warns and falls back to `mock` |
| `ActionAgent.code_session_backends` | `{}` | Extra backends, `name => class name`, merged over the built-ins. A backend is any object answering `launch`, `run`, `attach_command`, `status`, `terminate`, `features`, `supported_tools` and `healthy?` |
| `ActionAgent.code_session_limits` | `{ session_duration_minutes: 240, run_timeout_seconds: 3600, max_sessions_per_owner: 5 }` | Session expiry, the wall-clock cap on one headless run, and how many pending or running sessions one owner may hold |
| `ActionAgent.github_token_resolver` | `nil` | `->(owner, session) { token or nil }`. Consulted first; see [GitHub access](#github-access) |
| `ActionAgent.code_on_incus.binary` | `"coi"` | The CLI to invoke |
| `ActionAgent.code_on_incus.ssh_target` | `nil` | `user@host` when `coi` runs on another machine |
| `ActionAgent.code_on_incus.state_dir` | `Rails.root.join("tmp", "action_agent", "code_sessions")` | Where per-session profiles, briefs, secrets and workspaces are written (mode 0700). On the remote host when `ssh_target` is set |
| `ActionAgent.code_on_incus.base_profile` | `"hardened"` | The `coi` profile every session profile inherits |
| `ActionAgent.code_on_incus.image` | `nil` | Container image; unset uses the profile's default |
| `ActionAgent.code_on_incus.cpu_limit` / `memory_limit` | `"4"` / `"8GB"` | Written to the profile's `[limits]` |
| `ActionAgent.code_on_incus.allowlist` | GitHub, RubyGems, npm, PyPI and the Anthropic, OpenAI and Copilot APIs | Hosts reachable in `allowlist` network mode |

Code sessions sit behind the same switches as agent runs:
`ActionAgent.execution_enabled = false` disables creating and running them,
and each run counts against the execution quota.

## GitHub access

A session declares one of three access levels, and the brief's sandbox
section states which one was granted so the coding agent does not attempt
what it cannot do:

| `github_access` | What the container gets |
|---|---|
| `none` | An anonymous clone. Public repositories only; no push |
| `read` | A token for the clone. Private repositories work; the default task tells the coding agent not to push |
| `write` | A token the coding agent may use to push a branch and open a pull request |

The engine issues no GitHub tokens of its own (no GitHub App, no OAuth).
`ActionAgent.github_token_for(owner, session)` resolves one in this order:

1. `ActionAgent.github_token_resolver`, when set. The hosted platform uses
   this to hand out the workspace's token; a self-hosted install can return
   whatever its own integration holds.
2. A provider key with provider `github` owned by the current owner (Settings
   -> Provider API Keys -> *GitHub (code sessions)*). A fine-grained token
   scoped to the repository is enough; give it `contents: write` and
   `pull_requests: write` only for `write` sessions.
3. `ENV["GITHUB_TOKEN"]`, in single-tenant mode only. A multi-tenant install
   never falls back to the process environment, since one tenant's token
   must not reach another's session.

`read` and `write` do not distinguish tokens: the engine cannot narrow a
token's scope, so the level is enforced by the token you provide and stated
to the coding agent in the brief.

How the token travels: it is fetched when the provision job runs, written to
`<state_dir>/<session_id>/secrets/github_token` with mode 0600, and exposed
to the container through the profile's `[env_commands]`
(`GH_TOKEN = "cat .../secrets/github_token"`), so it never appears in a
command line, in the profile itself, or in a log. It is not stored in the
database, not returned by any API response, and the file is deleted when the
session is terminated. Error messages and transcripts that happen to contain
it are masked before they are saved. The `git clone` runs with an inline
credential helper that reads the same variable, so the token is never part
of the remote URL either. The `github_token` parameter name is added to
`filter_parameters`.

The coding tool's own credentials follow the same route: the owner's
provider keys (or, single-tenant, the environment) supply
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or `OPENROUTER_API_KEY` as the catalog
entry for the tool requires, written to `secrets/env` (0600) and read
through `[env_commands]`. The brief lists which of them are present by
variable name and never by value.

## What the brief contains

The brief is stored as JSON on the session, shown as panels in the form
preview and the session page, and rendered to Markdown for the container.
Everything in it comes from the current evaluation and metrics
implementation:

| Section | Source |
|---|---|
| Agent under improvement | The agent's provider, model, tools, MCP servers and the first 600 characters of its instructions |
| Needs | `ActiveAgent::Evals::Report#fix_items` of the newest complete scenario run: a `missing tools` or `suggested tools` fault becomes a `tool` need, or an `mcp_server` need when `EvaluationToolResolver` knows which server serves the tool and whether the agent has it enabled; an instruction fix item becomes an `instruction` need; a `429 rate limit` error type in the last 24 hours becomes a `credential` need |
| Limitations | `failing tools` fix items (`fault`), `missing_capability` results ("Cannot ..."), `run_error` / `low_quality` / `missing_content` / `forbidden_content` faults (`quality`), and from metrics an error rate above 5% (`reliability`) or a p95 above 10 s (`latency`) |
| Failing scenarios | `EvaluationScenarioResult` rows with a fault: prompt, model, fault, recommendation, tools called (at most 20) |
| Production signal | `ActionAgent::MetricsReport` narrowed to the agent's telemetry class over 24h: requests, error rate, p50/p95 latency, cost, tool error rate, errors by type. Omitted when there are no traces |
| Code agent | The catalog entry for the chosen tool: what an operator must provide, its known limitations, which credentials are present or missing (by name) |
| Sandbox | Backend, network mode, GitHub access, repository, and the constraints that follow from them |

Each need and limitation carries its evidence (fault, count, scenario keys,
models), and needs and limitations are capped at twelve entries each, most
frequent fault first. An agent with no evaluations gets a brief that says so
instead of an empty section, and a legacy sampled evaluation contributes only
its pass rate. `GET /api/code_sessions/:id/brief` returns both the JSON and
the Markdown; `POST /api/code_sessions/preview_brief` compiles one without
creating a session.

## Security

- **Isolation.** Each session is one Incus system container built from the
  `hardened` profile, non-persistent, with its own workspace mount. The
  brief and prompt are mounted read-only at `/brief`.
- **Network.** `restricted` (default) allows only what the base profile
  permits, so package installs may fail and the brief says so; `allowlist`
  opens the configured hosts plus the GitHub family and pins DNS; `open` is
  unrestricted and should be reserved for repositories you trust to run
  arbitrary code, which is what a coding agent does. Clones use HTTPS, so
  `github.com` must be reachable in every mode you intend to clone in.
- **Threat monitoring** is `coi`'s: the profile sets
  `auto_pause_on = "HIGH"` and `auto_kill_on = "CRITICAL"` and enables
  workspace secret masking. Read `coi audit` on the host.
- **No host secrets.** Nothing from the Rails process environment is
  forwarded except what `[env_commands]` reads from the session's own
  `secrets/` files. There is no SSH agent forwarding.
- **Nothing user-controlled reaches a shell.** The backend spawns argv
  arrays, never shell strings. Repository, branch, model and task are
  validated by the model (`owner/repo`, a branch name without a leading `-`
  or `..`, a 20 000 character task) and only ever appear as quoted TOML
  strings or as environment variables read by a fixed clone script.
- **Permission prompts are bypassed.** Headless runs set
  `permission_mode = "bypass"`: the coding agent edits and runs whatever it
  decides to inside the container. Review its diff before merging.

## Limitations

- Headless runs are confirmed only for **Claude Code** (`coi run
  --prompt-file`). Codex CLI, Copilot CLI, opencode and aider run through
  `coi run -- <command>` with a command the catalog marks *experimental*
  because the flags are not verified against every release; pi and Oh My Pi
  have no headless command in the catalog, so drive them through *Attach*.
  The form
  disables tools the current backend does not support and says why.
- No terminal in the browser. *Attach* copies
  `COI_CONFIG=<state>/profile/config.toml coi attach` (prefixed with
  `ssh -t <target>` when configured) for you to run locally.
- No GitHub App or OAuth in the engine. Tokens come from the host's resolver
  or a provider key you paste.
- Cost is estimated only when the tool prints token totals; otherwise it is
  blank rather than guessed.
- Status is best effort: `coi list --all` filtered by the session's
  container name, so a container killed on the host outside the engine
  shows `unknown` until the next poll.

## API

All routes live under the mount's `/api` and are scoped to the current
owner; a session that belongs to someone else is a 404.

| Method and path | Purpose |
|---|---|
| `GET /api/code_sessions` | Sessions plus the backend's name, health (cached 60 s) and features, and whether a GitHub token resolves |
| `GET /api/code_sessions/catalog` | The tool catalog with a `supported` flag per tool, backends, network and access modes, limits |
| `POST /api/code_sessions/preview_brief` | `agent_id`, `evaluation_run_id`, `tool`, `network_mode`, `github_access`, `repository` -> the brief and its Markdown, nothing persisted |
| `POST /api/code_sessions` | `code_session: { agent_id, evaluation_run_id, tool, backend, repository, branch, github_access, network_mode, model, task, run }`; 201 with the session, provisioning queued. 422 for an observed (read-only) agent, an unsupported tool, a bad repository, or an owner at `max_sessions_per_owner` |
| `GET /api/code_sessions/:id` | The session with brief, events, transcript and attach command |
| `GET /api/code_sessions/:id/brief` | Brief JSON and Markdown |
| `GET /api/code_sessions/:id/events` | Status, events, transcript, exit code; the UI polls it every 3 s while a session is pending, provisioning or running |
| `POST /api/code_sessions/:id/run` | Optional `prompt` overriding the task; 202, run queued. 422 unless the session is ready or completed and not expired |
| `POST /api/code_sessions/:id/stop` | Marks the session stopped and queues cleanup |
| `DELETE /api/code_sessions/:id` | Terminates the container and deletes the session |

Session JSON never contains tokens, credential values, or host paths beyond
the workspace the backend reports. Jobs (`CodeSessionProvisionJob`,
`CodeSessionRunJob`, `CodeSessionCleanupJob`) run on the `sandboxes` queue
without blanket retries, so a failed provision is reported once instead of
re-cloning in a loop; `CodeSessionCleanupJob.expire_stale!` is the method to
schedule for expiring sessions past `expires_at`.
