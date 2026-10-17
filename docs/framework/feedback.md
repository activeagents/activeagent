# User feedback

The Action Agent dashboard can collect thumbs up/down feedback about a recorded
agent interaction, with an optional comment. Open an agent and choose **Feedback**
to review ratings, comments, submission times, end-user references and trace links.
An optional span ID identifies the particular response within the trace.

This feature requires an actionagent version containing interaction feedback.
When upgrading an existing installation, run:

```sh
bin/rails generate action_agent:install
bin/rails db:migrate
```

The generator adds the interaction feedback migration and skips migrations that
are already present. Deploy the migration before the updated dashboard.

## Submit feedback from your application

Handle the thumbs buttons in your application, authenticate the end user there,
and submit feedback **from your server**. Keep the telemetry key in a server-side
secret; never embed it in browser JavaScript. Verify that the signed-in user can
access the interaction before forwarding the request.

POST to `<mount>/api/feedback`, where `<mount>` is `/activeagents` by default or
`/dashboard` on the hosted platform. Use the same Bearer key as trace ingestion:

```sh
curl "$DASHBOARD_URL/api/feedback" \
  -H "Authorization: Bearer $TELEMETRY_API_KEY" \
  -H 'Content-Type: application/json' \
  --data '{"feedback":{"trace_id":"trace-example","feedback_id":"vote-example","rating":"positive","comment":"Clear and useful.","span_id":"response-example","user_reference":"user-example"}}'
```

`DASHBOARD_URL` includes the engine mount. Values in this example are synthetic;
use the trace ID and span ID recorded by your application's telemetry.

| Field | Meaning |
| --- | --- |
| `trace_id` | Required external telemetry trace ID, already ingested. |
| `feedback_id` | Required stable ID for this vote, at most 128 characters. |
| `rating` | Required `positive` (thumbs up) or `negative` (thumbs down). |
| `comment` | Optional text, at most 5,000 characters. |
| `span_id` | Optional recorded span ID within this trace, at most 128 characters. |
| `user_reference` | Optional opaque end-user identifier, at most 255 characters. Avoid email addresses and unnecessary personal data. |

Use one stable `feedback_id` per end user and target response/interaction. Retries
with the same trace and feedback ID update that vote rather than adding another.
Reusing it lets a user change their rating or comment. Send `comment: null` to
clear a comment and `span_id: null` to change a response vote into a trace vote.
A new ID records a separate vote. The application owns this identity policy;
the dashboard's ingest key authenticates the workspace, not the end user.

Successful submissions return HTTP 200 with a `feedback` object. Missing or
incorrect credentials return 401 when authentication is configured. Unknown
traces, including traces outside the key's workspace, return 404. Because trace
ingestion can run asynchronously, retry 404 after ingestion completes with bounded
backoff. Invalid ratings, oversized fields or an unrelated span return 422.
Missing feedback envelopes return 400.

Single-user installations follow trace-ingest authentication: configure
`ActionAgent.ingest_api_key` whenever the mount is reachable beyond your machine.
Multi-tenant installations always require the account's telemetry key.

## Review feedback

Open **Agents → your agent → Feedback**. Filter by rating and submission date,
refresh after a new submission, and use **Open interaction trace** to inspect
the prompt and response. Response-specific votes also show their span ID.
Dates use the server's configured time zone; the end date includes that day.
Lists show 50 entries per page, newest first.

The summary reports positive and negative counts and the positive percentage
for all ratings matching the current filters, across all pages. For example,
3 positive and 1 negative produces 75% positive from 4 ratings. No ratings shows
an empty state rather than a zero satisfaction score. These are user votes,
separate from automated evaluations.

The dashboard reads `GET <mount>/api/feedback` using the dashboard session.
Optional query parameters are `agent_id`, `rating`, `from`, `to` and `page`.
Dates use `YYYY-MM-DD`. Response fields include `feedback`, `total`, `positive`,
`negative`, `positive_percentage` and `page`. Reads and submissions both scope
feedback through the associated workspace's traces.

Feedback currently attaches to ingested telemetry traces; a conversation that
has not produced an ingested trace cannot receive feedback through this endpoint.
