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
Anything else raises `Publisher::Error` (see [Errors and retries](#errors-and-retries)).
Save the report before calling the publisher so a rejected upload does not
discard an expensive evaluation. The publisher does not follow redirects.

To retry delivery without repeating model calls, load the saved report JSON and
pass that hash as `report`, with the **same** run ID and envelope identities. A
compatible collector treats the report as immutable within its authenticated
account: identical delivery is idempotent; different content with the same run
ID is a conflict. Never change the report's IDs between retries.

## Errors and retries

Every failure to deliver a report raises `Publisher::Error`. Arguments the
publisher cannot use raise `ArgumentError` before anything is sent:

- an endpoint that is not an HTTP(S) URL, uses plain HTTP off loopback, or carries credentials, a query or a fragment
- a missing or blank API key, or one with characters other than visible ASCII once surrounding whitespace is stripped
- a timeout that is not a positive, finite number
- a `run_id`, `source`, `agent_name` or `suite` that is not a nonblank string
- a `report` that is `nil`, an array, or anything else whose `to_h` does not return a hash

Besides its message, `Publisher::Error` carries:

| Attribute | Value |
|---|---|
| `status` | The collector's HTTP status (an Integer) when it rejected the delivery, otherwise `nil` |
| `detail` | The collector's explanation of a rejection, or `nil` when it gave none |
| `retryable?` | `true` when delivering the same report under the same `run_id` again may succeed |

A rejection's message names the status, the collector's explanation, and what
to do next:

```
Evaluation delivery rejected (HTTP 422: results[0].scenario_key is required); correct what the collector refused before retrying
```

The explanation is the `error` string of a JSON object body, the shape a
compatible collector returns. The rest of the body is ignored, and a body that
is not a JSON object with a string `error` gives no explanation. Control
characters and runs of whitespace become one space, the API key becomes
`[FILTERED]` if the collector echoes it, and the text is cut to 200 characters.
The publisher adds nothing from the request, the report or its headers; any
report content in the message is what the collector's own text quotes. A
collector should name the field it refused and keep report content, such as
answers and prompts, out of its `error`.

A rejection's guidance follows its status:

| Status | `retryable?` | What to do |
|---|---|---|
| 409 | `false` | The collector already holds a different report under this `run_id`, so this report can never be delivered under it. Publish the originally saved report, or give a separate run its own `run_id`. |
| 413 | `false` | The report exceeds the collector's size limit. Publish a smaller selection. |
| 422 | `false` | The collector refused something in the report or envelope, named in `detail`: a missing or invalid field, or a `suite` naming an evaluation this report does not belong to. Correct it and deliver again. |
| 429 | `true` | The account is over its quota or rate limit. Retry later with the saved report and the same `run_id`. |
| 408, 5xx | `true` | Retry later with the saved report and the same `run_id`. |
| 401, 403 | `false` | The collector refused the account: the API key is invalid, or the account may not deliver this report, for example because it has reached its limit of observed agents. Resolve it before retrying. |
| Other | `false` | Resolve the cause, such as the endpoint, before retrying. |

Failures without a collector rejection have a `nil` `status` and `detail`:

| Failure | `retryable?` |
|---|---|
| Network failure or timeout | `true` |
| Malformed response: a bad status line or header, or corrupt compression | `true` |
| Invalid receipt: a 200 or 201 body that is not JSON, or that does not report this `run_id` as complete | `true` |
| Report over the 2 MiB limit | `false` |
| Report that cannot be encoded as JSON: invalid UTF-8, `NaN` or `Infinity`, or nesting deeper than JSON allows | `false` |

The first three are retryable because the collector may already have stored
the report, and an identical delivery with the same `run_id` does not store it
twice. The last two are refused before the report leaves the process.

Only a network failure or timeout keeps the underlying error as the exception's
`cause`. No other `Publisher::Error` has a cause, so neither the response nor
the report reaches a log through the exception chain.

Bound retries: a retryable failure can persist, for example while a collector
is down, and a job that re-enqueues without a limit never stops.

```ruby
begin
  publisher.call(report: saved_report, run_id: run_id, source: "support-app",
    agent_name: "SupportBot", suite: "orders")
rescue ActiveAgent::Evals::Publisher::Error => error
  raise unless error.retryable? && attempt < 5
  PublishEvaluationJob.set(wait: 10.minutes * attempt).perform_later(run_id, attempt: attempt + 1)
end
```

## Limits and endpoints

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
