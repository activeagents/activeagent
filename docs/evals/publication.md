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
upload does not discard an expensive evaluation. Errors omit response bodies,
credentials, and report content. The publisher does not follow redirects.

To retry delivery without repeating model calls, load the saved report JSON and
pass that hash as `report`, with the **same** run ID and envelope identities. A
compatible collector treats the report as immutable within its authenticated
account: identical delivery is idempotent; different content with the same run
ID is a conflict. Never change the report's IDs between retries.

Reports are limited to 2 MiB per request. Select smaller scenario/model cohorts
when needed. HTTPS is required except for loopback development endpoints. The
default endpoint is `https://api.activeagents.ai/v1/evaluations`; applications
should allow an explicitly configured endpoint and enable publishing only after
the collector deployment supports this contract. Installing the gem alone does
not add ingestion to a host application.
