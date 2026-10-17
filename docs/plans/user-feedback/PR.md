# User feedback — review and testing

Issue: https://github.com/activeagents/activeagent/issues/591

Branch: `feat/591-interaction-feedback`

PR: pending publication.

## Validation

- Targeted Rails tests: 63 tests, 410 assertions, no failures/errors/skips.
  Includes feedback API, trace ingest, trace identity and install generator tests.
- UI test: passes with jsdom for ratings/comments, safe text rendering, mounted
  trace links, pagination, filter resets and error states.
- Dashboard production build: passes; committed JavaScript bundle updated.
- VitePress production build: passes, including the new User Feedback page.
- New migration applied successfully to the SQLite test host.

## Manual testing

1. Install the branch in a test host. Re-run
   `bin/rails generate action_agent:install`, then `bin/rails db:migrate`.
2. Configure the ingest key, ingest an agent trace and note its trace/span IDs.
3. Follow [the feedback submission example](../../framework/feedback.md), sending
   a positive vote with a comment and an optional response span.
4. Open the agent’s Feedback tab. Verify the comment, summary and trace link.
5. Submit the same feedback ID with a negative rating. Verify a single updated
   vote. Send a null comment to clear it.
6. Try rating/date filters, refresh, and pagination with more than 50 votes.
7. Try an invalid span, oversized comment, unknown trace and invalid key; check
   422, 404 and 401 responses as documented.
8. In a multi-tenant host, verify a second workspace cannot submit or read votes
   for the first workspace’s traces.

The public docs site publishes from main through the existing Pages workflow;
this PR updates its source. The feature covers ingested telemetry interactions;
conversations without an ingested trace are not feedback targets.
