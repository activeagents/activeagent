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

There are two, and they accept the same envelope and return the same receipt:

| Collector | Endpoint | Key |
|---|---|---|
| The hosted platform | `https://api.activeagents.ai/v1/evaluations` (the default) | An account API key |
| Any Rails app that mounts the `actionagent` engine | `<mount>/api/evaluation_reports`, e.g. `https://ops.example.com/activeagents/api/evaluation_reports` | The install's `ActionAgent.ingest_api_key`, or the tenant's key on a multi-tenant install |

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
| 201 | The report was stored. The receipt carries `id`, `evaluation_id`, `run_id`, `status: "complete"`, `duplicate: false` and `url`, the run's dashboard page (`<mount>/evaluations/:evaluation_id/runs/:id`). |
| 200 | The same report was already stored under this `run_id`; the receipt names the stored run, with `duplicate: true`. |
| 409 | A different report is already stored under this `run_id`, or the agent already has an evaluation of that name that no report with this source, suite and scope created. |
| 413 | The body is over 2 MiB. |
| 429 | The host's `quota_checker` denied `:evaluation_report`, the owner already holds as many observed agents as it can (`ActionAgent::AgentRegistrar::MAX_OBSERVED_PER_OWNER`), or the key has published more than 30 reports in a minute. |
| 400, 422 | The body is not JSON, or not a valid version-1 report (the error names the field). |
| 401 | No key, or the wrong one, when the mount requires one. |

A valid report has:

- `run_id`, `source` and `suite` of 1-200 characters with no control characters, and an
  `agent_name` of 2-100.
- Scope values (`scope`, `environment`, `role` in the report metadata) of 1-100 letters,
  digits, spaces or `. : / @ _ -`, which together with the suite name an evaluation of at
  most 255 characters.
- One result per scenario and model label, each label naming one provider/model and no two
  labels the same one.
- Token counts and durations that fit a 32-bit integer, and a cost below 1,000,000.
- Tool calls that are objects with a `name`, and a verdict and diagnosis in the shapes
  `ActiveAgent::Evals` writes.

NUL characters are removed from every string, and an answer is stored up to its first 20,000
bytes. The run's per-model summary, criterion scores and recommendations are computed from
its stored results; the judge's verdict and label are kept as the report gives them.

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
`ActionAgent.quota_checker`, which receives the tenant (nil on a single-tenant install). A
denial is a 429 whose body merges the checker's message or Hash. `ActionAgent.usage_recorder`
is called with `:evaluation_report` once for each stored report, and not again for an
identical retry.

```ruby
ActionAgent.configure do |config|
  config.quota_checker = ->(account, kind) {
    "Evaluation report allowance used up" if kind == :evaluation_report && account&.reports_exhausted?
  }
end
```
