# Command Line (`activeagent`)

The `activeagent` gem ships an `activeagent` executable that works with a
dashboard (a Rails app mounting the `actionagent` engine) over HTTP: list and
run evaluations, gate CI on a pass rate, move evaluation reports between
installs, import scenario catalogs, and read agents and traces. It needs only
the gem — not the host app's checkout or database — and loads neither Rails
nor the framework.

```bash
gem install activeagent        # or: bundle exec activeagent ...
activeagent login --url https://ops.example.com/activeagents --key aa_...
activeagent status
activeagent evals list
```

## Keys and profiles

The dashboard authenticates two kinds of key, and the CLI sends each where it
belongs:

| Key | Where it comes from | Used by |
|---|---|---|
| Dashboard API key (`--key`) | The dashboard's Settings → API Keys (`aa_...`) | Everything that reads or runs: the MCP facade at `<mount>/mcp` |
| Ingest key (`--ingest-key`) | `ActionAgent.ingest_api_key`, or the tenant's telemetry key on a multi-tenant install | `evals import` and `evals report`: the collector at `<mount>/api/evaluation_reports` |

The ingest key defaults to the API key, so set it only when the two differ.
A single-tenant install with no `ingest_api_key` accepts any ingest key.

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
`jq` and scripts. Options can go before or after the command.

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | A request failed or the dashboard refused it |
| 2 | Bad command line |
| 3 | No URL or key configured |
| 4 | An evaluation run failed, or passed below `--min-pass-rate` |
| 5 | The dashboard has no API-key endpoint for the command yet |

## Evaluations

```bash
activeagent evals list [--agent SLUG] [--limit N]
activeagent evals runs EVALUATION
activeagent evals run EVALUATION [--models a,b] [--keys k1,k2] [--group G] [--sandbox ID]
                                 [--wait] [--min-pass-rate 0.8] [--timeout 1800] [--interval 5]
activeagent evals report RUN [--format json|html|md] [-o FILE]
activeagent evals import FILE [--run-id ID --source NAME --agent NAME --suite NAME]
```

`EVALUATION` is an evaluation's id or its exact name.

### Gating CI on a pass rate

`evals run --min-pass-rate` starts the run, waits for it (polling every
`--interval` seconds, up to `--timeout`), prints the failed results with
their traces, and exits 4 when the run failed or passed less than the
threshold. The rate is `0.8` or `80%`.

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

`evals import` posts a saved report to the collector with
`ActiveAgent::Evals::Publisher`. The file is a version-1 envelope, or a bare
`Report#to_h` hash with the identities given as options (`run_id` defaults to
the report's `metadata.run_id`). Importing the same report again is a no-op;
a different report under the same `run_id` is refused.

`evals report` reads one back from `GET <mount>/api/evaluation_reports/:run_id`:

- `--format json` — the version-1 envelope, so `evals report` on one install
  then `evals import` on another copies a run between them.
- `--format html` — the standalone HTML report.
- `--format md` — GitHub-flavored Markdown, for a pull request comment.

Without `--format`, a terminal gets Markdown and anything else (a pipe, or
`-o FILE`) gets JSON, so scripts always see JSON unless they ask otherwise.

```bash
activeagent evals report run-2026-10-21 --format json -o report.json
ACTIVEAGENT_PROFILE=production activeagent evals import report.json

activeagent evals report run-2026-10-21 --format md | gh pr comment 123 --body-file -
```

The report endpoint arrives with the dashboard's report export; on a
dashboard that predates it, `evals report` exits 5.

## Scenario catalogs

```bash
activeagent catalogs list
activeagent catalogs import FILE [--name KEY]
```

`catalogs import` takes the YAML document (`catalog:`, `products:` with
`sets:` of `scenarios:`). Products, sets and scenarios are matched by key, so
importing the same file twice changes nothing. Importing needs the
`replace_scenarios` permission for the key's user.

## Agents and traces

```bash
activeagent agents list
activeagent traces list [--agent NAME] [--since 24h] [--status error|ok] [--service NAME] [--limit N]
```

`--since` takes minutes or a duration such as `30m`, `6h` or `7d` (at most
the dashboard's trace window).

## Not yet available

These commands exist but exit 5, because their dashboard routes only accept
a browser session today. Each needs an API-key-authenticated endpoint
([#619](https://github.com/activeagents/activeagent/issues/619)):

| Command | Needs |
|---|---|
| `catalogs export KEY` | `GET <mount>/api/scenario_catalogs/:id/export` |
| `catalogs import FILE --preview` | `POST <mount>/api/scenario_catalogs/preview` |
| `agents versions AGENT` | `GET <mount>/api/agents/:id/versions` |

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
| `catalogs list` / `import` | MCP `catalogs_list` / `catalogs_import` | API key |
| `agents list` | MCP `resources/list` | API key |
| `traces list` | MCP `traces_search` | API key |

The MCP commands use the facade's dashboard tools. An install that sets
`ActionAgent.mcp_dashboard_tools = false` turns them off, and those commands
then exit 5.
