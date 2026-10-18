# Interaction user feedback — issue #591

Issue: https://github.com/activeagents/activeagent/issues/591

End users need to rate an interaction or response with thumbs up/down and an
optional comment; operators need to review the votes in the dashboard.

The engine now stores feedback separately from traces. Authenticated application
servers submit votes; the dashboard reads them through workspace-scoped traces.
The application is responsible for authenticating end users and authorizing the
target interaction before forwarding a vote.

See [user-facing documentation](../../framework/feedback.md) and
[review/testing notes](PR.md).
