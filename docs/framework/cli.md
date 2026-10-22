# Command Line (`activeagent`)

The `activeagent` gem ships an `activeagent` executable that works with a
dashboard (a Rails app mounting the `actionagent` engine) over HTTP: list and
run evaluations, gate CI on a pass rate, move evaluation runs, scenario
catalogs and traces between installs as files, and read agents and traces. It
needs only the gem — not the host app's checkout or database — and loads
neither Rails nor the framework.

```bash
gem install activeagent        # or: bundle exec activeagent ...
activeagent login --url https://ops.example.com/activeagents --key aa_...
activeagent status
activeagent evals list
```

It needs `actionagent` 1.9.3 or later on the dashboard, with the facade's
dashboard tools on (the default). An older dashboard, or one that set
`ActionAgent.mcp_dashboard_tools = false`, answers the commands that need
them with exit code 5.

## Keys and profiles

The dashboard authenticates two kinds of key, and the CLI sends each where it
belongs:

| Key | Where it comes from | Used by |
|---|---|---|
| Dashboard API key (`--key`) | The dashboard's Settings → API Keys (`aa_...`) | Everything that reads or runs: the MCP facade at `<mount>/mcp` |
| Ingest key (`--ingest-key`) | `ActionAgent.ingest_api_key`, or the tenant's telemetry key on a multi-tenant install | What the framework's own reporters post with: `evals import` and `evals report` (the report collector at `<mount>/api/evaluation_reports`) and `traces import` (trace ingest at `<mount>/api/traces`) |

The ingest key defaults to the API key, so set it only when the two differ.
A single-tenant install with no `ingest_api_key` accepts any ingest key for
the imports, but refuses `evals report` until one is set (every stored run
would otherwise be readable under its run id by anyone who reaches the
mount).

`login` checks the API key against the dashboard (skip with `--no-verify`)
and stores the profile in `~/.config/activeagent/credentials.yml`
(`$XDG_CONFIG_HOME` when set), created `0600` in a `0700` directory. Without
`--key` it reads the key from a prompt with echo off, or from standard input,
so the key need not reach shell history:

```bash
activeagent login --url https://ops.example.com/activeagents --profile staging
activeagent evals list --profile staging
activeagent logout --profile staging
```

The URL is the engine's mount, including its path. HTTPS is required except
on `localhost`.

In CI, set the environment instead of a profile. It overrides any stored
profile:

| Variable | Meaning |
|---|---|
| `ACTIVEAGENT_URL` | The dashboard mount |
| `ACTIVEAGENT_API_KEY` | The dashboard API key |
| `ACTIVEAGENT_INGEST_KEY` | The ingest key, when it differs |
| `ACTIVEAGENT_PROFILE` | The stored profile to use (default `default`) |

`activeagent status` checks both keys: the API key against the MCP facade and
the ingest key against the collector (`Publisher#verify!`, which stores
nothing).

## Output and exit codes

Commands print tables. `--json` prints the dashboard's JSON instead, for
`jq` and scripts. Options can go before or after the command. A command that
writes a document (`evals report`, `catalogs export`, `traces export`)
prints it, or writes it to `-o FILE` and says so on standard error.

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | A request failed or the dashboard refused it |
| 2 | Bad command line |
| 3 | No URL or key configured |
| 4 | An evaluation run failed, or passed below `--min-pass-rate` |
| 5 | The dashboard does not offer what the command needs: an older engine, or its dashboard tools turned off |

## Evaluations

```bash
activeagent evals list [--agent SLUG] [--limit N]
activeagent evals runs EVALUATION
activeagent evals run EVALUATION [--models a,b] [--keys k1,k2] [--group G] [--sandbox ID]
                                 [--wait] [--min-pass-rate 0.8] [--timeout 1800] [--interval 5]
activeagent evals report RUN [--format json|html|md] [-o FILE]
activeagent evals import FILE [--run-id ID --source NAME --agent NAME --suite NAME]
```

`EVALUATION` is an evaluation's id or its exact name. `evals runs` lists an
evaluation's runs with their `RUN_ID`, the handle `evals report` takes: a run
an application published keeps its own `run_id`, and a run the dashboard
executed is `dashboard-run-<id>-<created_at>`.

### Gating CI on a pass rate

`evals run --min-pass-rate` starts the run, waits for it (polling every
`--interval` seconds, up to `--timeout`), prints the failed results with
their traces and the `evals report` command for the run, and exits 4 when
the run failed or passed less than the threshold. The rate is `0.8` or
`80%`.

```yaml
# .github/workflows/evals.yml
- run: bundle exec activeagent evals run "Support orders" --models gpt-5-mini --min-pass-rate 0.9
  env:
    ACTIVEAGENT_URL: https://ops.example.com/activeagents
    ACTIVEAGENT_API_KEY: ${{ secrets.ACTIVEAGENT_API_KEY }}
```

A scenario suite's replays run the agent on the dashboard, so the run needs
execution enabled there and counts against its execution quota.

### Reports

`evals report` reads a complete run back from
`GET <mount>/api/evaluation_reports/:run_id`
(see [Exporting a stored run](/evals/publication#exporting-a-stored-run)):

- `--format json` — the version-1 envelope `ActiveAgent::Evals::Publisher`
  sends, so `evals report` on one install then `evals import` on another
  copies a run between them, and importing it back where it came from is
  an identical retry.
- `--format html` — the standalone HTML report page, following the viewer's
  light or dark preference.
- `--format md` — GitHub-flavored Markdown, for a pull request comment.

Without `--format`, a terminal gets Markdown and anything else (a pipe, or
`-o FILE`) gets JSON, so scripts always see JSON unless they ask otherwise.
A run id the dashboard holds no complete run under exits 1; a dashboard
with no report export at all (before `actionagent` 1.9.3) exits 5.

`evals import` posts a saved report to the collector with
`ActiveAgent::Evals::Publisher`. The file is a version-1 envelope, or a bare
`Report#to_h` hash with the identities given as options (`run_id` defaults to
the report's `metadata.run_id`). Importing the same report again is a no-op;
a different report under the same `run_id` is refused.

```bash
activeagent evals report run-2026-10-21 --format json -o report.json
ACTIVEAGENT_PROFILE=production activeagent evals import report.json

activeagent evals report run-2026-10-21 --format md | gh pr comment 123 --body-file -
```

## Scenario catalogs

```bash
activeagent catalogs list
activeagent catalogs import FILE [--name KEY] [--mode replace|merge] [--preview]
activeagent catalogs export KEY [--product KEY [--set KEY]] [--format yaml|json] [-o FILE]
```

`catalogs import` takes the catalog document (`catalog:`, `products:` with
`sets:` of `scenarios:`; see [Catalogs](/framework/evaluations#catalogs)),
as YAML or as the JSON `catalogs export --format json` writes. Products, sets
and scenarios are matched by key, so importing the same file twice changes
nothing; `--mode replace` (the default) makes the catalog the document, and
`--mode merge` keeps what the document leaves out. `--preview` shows what the
import would do — whether the catalog would be created, how many products,
sets and scenarios would be created, updated, removed or kept, and each
change by path — and writes nothing. Importing needs the `replace_scenarios`
permission for the key's user; previewing and exporting need only the key.

`catalogs export` writes the canonical document from the dashboard's records
(the same document the Catalogs page's Export YAML downloads): the whole
catalog, or one product or one set of it, as a document of the catalog's key
that `--mode merge` reads back in. `-o FILE` ending in `.json` writes JSON.

```bash
activeagent catalogs export support_desk -o .activeagents/evals/support_desk.yml
activeagent catalogs import .activeagents/evals/support_desk.yml --preview
activeagent catalogs export support_desk --product triage --set smoke --format json
```

## Agents

```bash
activeagent agents list
activeagent agents versions AGENT [--limit N]
```

`agents versions` lists an agent's versions newest first: who made each,
whether it was cut from the agent's code on deploy (a release, with its
revision) or edited on the dashboard, and which fields it changed
(`--json` has the full diff).

## Traces

```bash
activeagent traces list [--agent NAME] [--since 24h] [--status error|ok] [--service NAME] [--limit N]
activeagent traces get TRACE
activeagent traces export TRACE [-o FILE]
activeagent traces import FILE
```

`--since` takes minutes or a duration such as `30m`, `6h` or `7d` (at most
the dashboard's trace window). `TRACE` is a trace's id, its OpenTelemetry
trace id, or that id's first 8 characters, as `traces list` shows it.

`traces get` shows a trace as the dashboard's trace page does: its spans,
tool calls and errors, with long values cut. `traces export` writes the trace
whole, as the payload `POST <mount>/api/traces` ingests (`{ "traces": [...],
"sdk": {...} }`, with the owner's credentials masked), and `traces import`
posts such a file — or one trace object, or a reporter's batch — to the
dashboard's trace ingest with the ingest key. A trace id the dashboard
already holds is skipped there, so importing the same file twice stores
nothing more.

```bash
activeagent traces export 4f1c9b2a -o trace.json
ACTIVEAGENT_PROFILE=local activeagent traces import trace.json
activeagent traces get 4f1c9b2a --profile local
```

## Where each command goes

| Command | Endpoint | Key |
|---|---|---|
| `login`, `status` | `POST <mount>/mcp` `initialize` | API key |
| `status` | `POST <mount>/api/evaluation_reports` (empty envelope) | Ingest key |
| `evals list` | MCP `evaluations_list` | API key |
| `evals runs` | MCP `evaluations_get` | API key |
| `evals run` | MCP `evaluations_run`, then `evaluation_runs_get` | API key |
| `evals import` | `POST <mount>/api/evaluation_reports` | Ingest key |
| `evals report` | `GET <mount>/api/evaluation_reports/:run_id` | Ingest key |
| `catalogs list` / `import` / `import --preview` / `export` | MCP `catalogs_list` / `catalogs_import` / `catalogs_preview` / `catalogs_export` | API key |
| `agents list` / `versions` | MCP `resources/list` / `agents_versions` | API key |
| `traces list` / `get` / `export` | MCP `traces_search` / `traces_get` / `traces_export` | API key |
| `traces import` | `POST <mount>/api/traces` | Ingest key |

The MCP commands use the facade's
[dashboard tools](/framework/dashboard#evaluations-and-telemetry-from-your-coding-harness).
An install that sets `ActionAgent.mcp_dashboard_tools = false` turns them
off, and those commands then exit 5. The rake tasks
(`action_agent:evaluations:export|import`, `action_agent:catalogs:import|export|run`)
do the same work inside the host app, without a key.
