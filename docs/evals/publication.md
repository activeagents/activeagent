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

The collector endpoint is `/v1/evaluations`. The version-1 JSON envelope contains
`version`, `run_id`, `source`, `agent_name`, `suite`, and `report` (the existing
`Report#to_h` shape). Authorization uses the account's Bearer API key. Result
correlation belongs in each result's `metadata`: `result_id`, `trace_id`, and
`judge_trace_ids`. Run-level judge traces can be retained in report metadata.
Applications assign these IDs and propagate the same IDs into telemetry.

Delivery is synchronous. A valid receipt has HTTP 201 (new) or 200 (identical
retry), the same `run_id`, `status: "complete"`, `id`, and `evaluation_id`.
Other statuses, invalid receipts, connection failures, and timeouts raise
`Publisher::Error`. Save the report before calling the publisher so a rejected
upload does not discard an expensive evaluation. The publisher does not follow
redirects.

To retry delivery without repeating model calls, load the saved report JSON and
pass that hash as `report`, with the **same** run ID and envelope identities. A
compatible collector treats the report as immutable within its authenticated
account: identical delivery is idempotent; different content with the same run
ID is a conflict. Never change the report's IDs between retries.

## Errors and retries

`Publisher::Error` is the one class to rescue. Besides its message it carries:

| Attribute | Value |
|---|---|
| `status` | The collector's HTTP status (an Integer) when it rejected the delivery; `nil` for a network failure, a timeout, an invalid receipt, or a report over the 2 MiB limit |
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

| Status | `retryable?` | What to do |
|---|---|---|
| 409 | `false` | The collector already holds a different report under this `run_id`, so this report can never be delivered under it. Publish the originally saved report, or give a separate run its own `run_id`. |
| 413 | `false` | The report exceeds the collector's size limit. Publish a smaller selection. |
| 422 | `false` | The collector refused a field of the report or envelope, named in `detail`. Correct it and retry with the same `run_id`. |
| 429 | `true` | The account is over its quota or rate limit. Retry later with the saved report and the same `run_id`. |
| 408, 5xx | `true` | Retry later with the saved report and the same `run_id`. |
| Other | `false` | Resolve the cause, such as the API key or the endpoint, before retrying. |

Network failures, timeouts, and invalid receipts are retryable: the collector
may already have stored the report, and an identical delivery with the same
`run_id` does not store it twice. A report over the 2 MiB limit is refused
before it leaves the process and is not retryable.

```ruby
begin
  publisher.call(report: saved_report, run_id: run_id, source: "support-app",
    agent_name: "SupportBot", suite: "orders")
rescue ActiveAgent::Evals::Publisher::Error => error
  raise unless error.retryable?
  PublishEvaluationJob.set(wait: 10.minutes).perform_later(run_id)
end
```

## Limits and endpoints

Reports are limited to 2 MiB per request. Select smaller scenario/model cohorts
when needed. HTTPS is required except for loopback development endpoints. The
default endpoint is `https://api.activeagents.ai/v1/evaluations`; applications
should allow an explicitly configured endpoint and enable publishing only after
the collector deployment supports this contract. Installing the gem alone does
not add ingestion to a host application.
