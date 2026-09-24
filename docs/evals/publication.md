# Publishing an externally executed evaluation

`ActiveAgent::Evals::Publisher` sends a completed report to a compatible
ActiveAgents collector. It does not execute an agent. Keep report publication
opt-in: the payload contains the report's prompts, answers and tool results.

```ruby
require "active_agent/evals"

receipt = ActiveAgent::Evals::Publisher.new(
  endpoint: ENV.fetch("ACTIVEAGENTS_EVALUATIONS_ENDPOINT"),
  api_key: ENV.fetch("ACTIVEAGENTS_API_KEY")
).call(
  report: report,
  run_id: report.metadata.fetch("run_id"),
  source: "support-app", agent_name: "SupportBot", suite: "orders"
)
```

## Collectors

A collector is either the hosted platform or a Rails app that mounts the
`actionagent` engine. Both take the same envelope and return the same receipt:

| Collector | Endpoint | Key |
|---|---|---|
| The hosted platform, when it offers one | `https://api.activeagents.ai/v1/evaluations` (the publisher's default) | An account API key |
| A full install of the `actionagent` engine (not one generated with `--traces-only`) | `<mount>/api/evaluation_reports`, e.g. `https://ops.example.com/activeagents/api/evaluation_reports` | The install's `ActionAgent.ingest_api_key`, or the tenant's key on a multi-tenant install |

A self-hosted collector authenticates exactly as the engine's trace ingest
endpoint does, so an application that already reports traces to a mount
publishes its reports there with the same key:

```bash
ACTIVEAGENTS_EVALUATIONS_ENDPOINT=https://ops.example.com/activeagents/api/evaluation_reports
ACTIVEAGENTS_API_KEY=<the mount's ingest_api_key>
```

The engine stores the report as its own evaluation rows, so the dashboard's
Evaluations page shows it the way it shows a run the dashboard executed. See
[Self-hosted collector](#self-hosted-collector) below.

## The envelope and the receipt

The version-1 JSON envelope contains `version`, `run_id`, `source`,
`agent_name`, `suite`, and `report` (the existing `Report#to_h` shape).
Authorization is a Bearer API key. Result correlation belongs in each result's
`metadata`: `result_id`, `trace_id`, and `judge_trace_ids`. Run-level judge
traces can be retained in report metadata. Applications assign these IDs and
propagate the same IDs into telemetry.

Delivery is synchronous. A valid receipt has HTTP 201 (new) or 200 (identical
retry), the same `run_id`, `status: "complete"`, `id`, and `evaluation_id`.
Other statuses, invalid receipts, connection failures, and timeouts raise
`Publisher::Error`. Save the report before calling the publisher so a rejected
upload does not discard an expensive evaluation. Errors omit response bodies,
credentials, and report content. The publisher does not follow redirects.

To retry delivery without repeating model calls, load the saved report JSON and
pass that hash as `report`, with the **same** run ID and envelope identities. A
compatible collector treats the report as immutable within its authenticated
account: identical delivery is idempotent; different content with the same run
ID is a conflict. Never change the report's IDs between retries.

Reports are limited to 2 MiB per request. Select smaller scenario/model cohorts
when needed. HTTPS is required except for loopback development endpoints.
Applications should allow an explicitly configured endpoint and enable
publishing only after the collector deployment supports this contract.
Installing `activeagent` alone does not add ingestion to a host application;
mounting `actionagent` does.

## Self-hosted collector

`POST <mount>/api/evaluation_reports` is served by
`ActionAgent::Api::EvaluationReportsController` and stored by
`ActionAgent::EvaluationReportImport`. It never executes the reporting
application's agent.

| Response | When |
|---|---|
| 201 | The report was stored. The receipt carries `id`, `evaluation_id`, `run_id` (exactly as sent), `status: "complete"`, `duplicate: false` and `url`, the run's dashboard page (`<mount>/evaluations/:evaluation_id/runs/:id`). |
| 200 | The same report was already stored under this `run_id`; the receipt names the stored run, with `duplicate: true`. A retry is answered before the quota and the rate limit are consulted, so a report that used the last unit of either still gets its receipt. |
| 409 | A different report is already stored under this `run_id`. |
| 422 | The report is not a valid version-1 report (the error names the field), or the agent already has an evaluation of that name that no report with this source, suite and scope created: publish under another suite or scope. |
| 403 | Storing the report needs an operator first: the owner holds as many observed agents as it can (`ActionAgent::AgentRegistrar::MAX_OBSERVED_PER_OWNER`), the agent holds 100 evaluations, the evaluation would hold more than 2,000 scenarios, or `trace_owner_resolver` placed the tenant's agent nowhere. |
| 429 | A new report the host's `quota_checker` denied as `:evaluation_report`, or one past 30 new reports a minute from the key. |
| 413 | The body is over 2 MiB, chunked or not; the collector reads no further than that. |
| 415 | The body is not declared `Content-Type: application/json`. |
| 400 | The body is not JSON. |
| 401 | No key, or the wrong one, when the mount requires one. |
| 501 | The install has no evaluation tables (it was generated with `--traces-only`), or has not run the migrations this collector needs. |
| 503 | Another report for the same agent was being stored for too long (MySQL); retry shortly. |

A valid report has:

- `run_id`, `source` and `suite` of 1-200 characters, and an `agent_name` of 2-100, none with
  a control character (NUL included). A `run_id` is compared exactly, case and accents
  included, on every database.
- Scope values (`scope`, `environment`, `role` in the report metadata) of 1-100 letters,
  digits, spaces or `. : / @ _ -`, which together with the suite name an evaluation of at
  most 255 characters.
- One result per scenario and model label, each label naming one provider/model and no two
  labels the same one.
- Token counts and durations that fit a 32-bit integer, and a cost below 1,000,000.
- Tool calls that are objects with a `name`, and a verdict and diagnosis in the shapes
  `ActiveAgent::Evals` writes, with each result's `fault` and `recommendation` equal to its
  diagnosis's (both absent is fine), as `Result#to_h` writes them.

NUL characters are removed from every string inside `report`. An answer is stored up to its
first 20,000 bytes, and a prompt, error or recommendation up to its first 65,535, what a MySQL
TEXT column holds; the result's scenario snapshot and diagnosis keep the whole text. The
run's per-model summary, criterion scores and recommendations are computed from its stored
results; the judge's verdict and label are kept as the report gives them, and a report with
no judge is recorded as scored on rules.

### Where a report lands

| Record | Identity |
|---|---|
| Agent | The observed agent for the envelope's `source` and `agent_name`. It is read-only, like the agents trace ingest observes. |
| Evaluation | That agent's evaluation named for the `suite`, qualified by the report metadata's `scope`, `environment` and `role`, in that order: `orders (eu, support)`. |
| Scenarios | One per reported scenario key, updated to the prompt and group the report ran. Scenarios the report did not run are left alone. |
| Run | One complete run per tenant and `run_id`, with one scenario result per scenario and model. Each result keeps its `metadata` (`result_id`, `trace_id`, `judge_trace_ids`). |

On a single-tenant install the agent has no owner, as a traced agent has none, and a
`run_id` is unique across the install. On a multi-tenant install the tenant is the account
the key names: the agent is owned by whatever `ActionAgent.trace_owner_resolver` returns for
a trace of that account (the account itself when it is unset), so it appears in that
tenant's dashboard beside its traced agents, and a `run_id` is unique within the tenant.

The run cannot be started again from the dashboard, because its agent runs elsewhere.
Evaluate again from the application and publish the new run.

### Metering

A host that meters its install answers the new `:evaluation_report` kind from
`ActionAgent.quota_checker`, which receives the tenant (nil on a single-tenant install). It
is asked only for a report that would be stored, never for an identical retry, and a denial
is a 429 whose body merges the checker's message or Hash. `ActionAgent.usage_recorder` is
called with `:evaluation_report` once for each stored report, and not again for a retry. A
report post does not call the tenant's `increment_telemetry_usage!`, which counts trace
ingest requests.

```ruby
ActionAgent.configure do |config|
  config.quota_checker = ->(account, kind) {
    "Evaluation report allowance used up" if kind == :evaluation_report && account&.reports_exhausted?
  }
end
```
