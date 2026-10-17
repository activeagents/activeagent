# Release 1.9.1

Issue: https://github.com/activeagents/activeagent/issues/591

PR: https://github.com/activeagents/activeagent/pull/597

Branch: `feat/591-interaction-feedback`

Milestone: include interaction feedback in the 1.9.1 release.

## Contents

- Thumbs up/down with an optional comment, trace/span attribution and vote updates.
- Authenticated ingestion, workspace-scoped dashboard review and filters.
- Install migration 027 and docs.activeagents.ai user feedback guide.
- Version 1.9.1 for activeagent, actionagent and the matching browser sidecar.

## Release checks

- [x] Targeted feedback, ingestion, identity and generator tests passed before version bump.
- [x] UI test, style checks, dashboard and documentation builds passed.
- [x] Build and inspect both 1.9.1 gem archives.
- [ ] PR CI succeeds and changes merge to main.
- [ ] Tag v1.9.1 and verify release workflow publication.

The tag invokes the repository's integration-gated trusted-publishing workflow.
The npm sidecar publish is staged and may require the maintainer's 2FA approval.
