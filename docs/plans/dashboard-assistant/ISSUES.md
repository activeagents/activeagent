# Dashboard assistant issues and milestones

Date: 2026-09-09. Branch: `codex/dashboard-evidence-assistant`.
Base: `1ab417d721b1d636144d0e83f38a4f0f48943dd6`.
Status: M1 implemented; validated with automated checks and synthetic browser review.
M1.5 and M2–M5 remain planned. No remote issues opened; see [PR.md](PR.md)
for the implementation PR.

Native product interaction adds M1.5: registry, browser connection, and real
builder/eval actions, with sandbox integration in M3. See
[PRODUCT_TOOLS.md](PRODUCT_TOOLS.md) for the implementation gaps and acceptance
criteria. This extension uses ActiveAgents directly without a Tidewave runtime
dependency; it is planned, not covered by the existing M1 test results.

This list records concrete gaps and acceptance criteria for [PLAN.md](PLAN.md)
and [WORKFLOW.md](WORKFLOW.md). The IDs below are document-local labels, not
GitHub issue numbers. All examples and proposed tests use synthetic data.

## DA-01 — Answer capability questions from scoped report evidence

Milestone: M1. Status: implemented; validated with automated checks and synthetic browser review.

The dashboard needs to answer a question such as “What can this agent demo?”
without asking the developer to inspect each report manually. Report discovery
must use host authorization and return the exact recorded prompt and result IDs.

Acceptance: one owner cannot retrieve another owner's report through search,
follow-up, guessed IDs or model tool calls. Results disclose selection/search
limits; a newer comparable failure supersedes an older pass. Historical passes
remain historical when no verified branch provenance exists. Server-issued
evidence cards remain inspectable independently of the model's prose.

Implemented: owner-scoped evidence tools, bounded search coverage, recorded
replay prompts, superseded-pass handling and historical-only candidate labels.

## DA-02 — Preserve historical inputs and classify weak evidence

Milestones: M1 safeguard; M2 full manifest. Status: historical prompt and caveat
safeguards implemented, validated with automated checks and synthetic browser review; immutable manifest proposed.

A current scenario or agent record can change after a run. Historical prompts,
instructions, expectations and tools must not be reconstructed from mutable
records. A format check, empty-result response or clarification can pass without
demonstrating the user's desired behavior.

Acceptance: retain recorded inputs where available; explicitly mark missing
legacy provenance. Show the checks that produced a pass. Separate substantive
behavioral validation, limited checks, empty results, missing context, skipped
cases and setup failures. Add known-fixture assertions and rubric/version
metadata before claiming content correctness. Do not claim current-main
verification from a historical report.

M1 discloses missing provenance and mutable rubrics, and identifies limited
recorded checks. It does not add immutable manifests or certify answer fidelity.

## DA-03 — Create a reviewable agent draft through conversation

Milestone: M1. Status: implemented; validated with automated checks and synthetic browser review.

The assistant should translate a requested responsibility into proposed
instructions and a permitted tool selection. It needs a model-backed dialogue,
validated draft schema and a handoff to the existing builder.

Acceptance: reject unknown tools and invalid fields; bound message history,
tool rounds and result sizes. Missing credentials return a Settings action.
Model proposals perform no save or repository execution. Review in builder
preserves the displayed instructions and tool selection; the builder save
remains explicit and uses the host's session/CSRF rules.

Implemented: explicit provider/model selection and provider-processing opt-in,
enforced before generation or report-tool access; validated server-issued drafts
and review-before-save builder handoff. SDK HTTP integration tests use synthetic
fixtures with external networking blocked. Live model answer quality remains
unverified by those tests.

## DA-04 — Make current-branch evaluation reproducible

Milestone: M2. Status: proposed; no immutable repository run manifest yet.

Acceptance: trusted runner signs or otherwise authenticates a versioned manifest
containing exact repository/head/base SHAs, rendered agent/tool/suite snapshots,
fixtures, model and judge settings, lockfile/runtime digests, timestamps and
result integrity references. Resolve main freshly before labeling a report
current. Reject stale-SHA check completion and preserve each attempt. A passing
result whose runtime or dataset differs is identified as a different context.

## DA-05 — Connect selected GitHub repositories without exporting credentials

Milestone: M3. Status: proposed; connection APIs not implemented in M1.

Acceptance: session-bound callback state, installation/repository selection,
host-user authorization and revoked-access handling. Issue short-lived tokens
restricted to approved repositories and operations. Keep the App private key and
write credentials outside untrusted workers and logs. Existing reports can be
read without requesting a new GitHub connection.

Reference: [GitHub installation authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation).

## DA-06 — Replace mock execution with a verified COI worker

Milestone: M3. Status: proposed. The engine ships the in-memory mock backend and
host registration seam; those do not implement repository execution.

Acceptance: exact-SHA checkout, fresh tenant-scoped workspace, constrained egress,
fixture isolation, resource/model budgets, cancellation, cleanup, artifact
redaction and trusted result collection. Dependency installation and repository
commands cannot access GitHub publishing credentials or certify their own run.
Expose unsupported capability state until a real backend passes integration
checks. Preserve setup failures as setup failures.

References: [Code on Incus](https://github.com/mensfeld/code-on-incus),
[network isolation](https://github.com/mensfeld/code-on-incus/wiki/Network-Isolation).
The documented restricted network mode permits public internet; it does not
replace an application-specific egress policy.

## DA-07 — Keep native coding sessions separate from hosted API credentials

Milestone: M4. Status: proposed; no Claude Code connection or handoff API in M1.

Acceptance: native handoff uses the unmodified binary and native authentication;
the application never captures or intermediates Claude.ai tokens. Hosted SDK
execution uses supported application API/provider credentials and displays its
billing context. Session resume restores conversation state separately from an
explicit workspace snapshot or pinned checkout and patch.

References: [Claude Code legal and compliance](https://code.claude.com/docs/en/legal-and-compliance),
[Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview),
[session management](https://code.claude.com/docs/en/agent-sdk/sessions).

## DA-08 — Turn failed evaluations into reviewed repairs

Milestone: M4. Status: proposed.

Acceptance: failure card links actual versus expected behavior and relevant
tool trace; repair task changes only the selected workspace. Compare original
and repaired scenarios, then run relevant regressions. Display the patch,
remaining failures and test evidence before publication. A generated change
does not itself count as an improved evaluation result.

## DA-09 — Publish checks for the exact PR commit

Milestone: M5. Status: proposed; no webhook or check publisher in M1.

Acceptance: verify webhook signature, deduplicate delivery and run attempts,
bind every check to the authorized repository and exact tested SHA. Handle
cancellation, new commits, forks and installation revocation. Distinguish
behavior regressions from setup failures and non-evaluated cases. A trusted
publisher writes checks; untrusted code never gets Checks/Contents/PR tokens.
Opening a draft PR requires the scoped user action or an already authorized
repository policy after a concrete diff and test report are available.

References: [validating webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries),
[check runs](https://docs.github.com/en/rest/checks/runs).

## DA-10 — Persist durable tasks and protect their artifacts

Milestones: M2–M4. Status: proposed. M1 conversation history is bounded and local
to the browser tab.

Acceptance: owner-scoped durable task/session identity, reconnectable progress,
run/attempt lifecycle, idempotent cancellation and retention controls. Recheck
access for each artifact retrieval. Scrub credentials and sensitive record dumps
before displaying or publishing reports; preserve restricted originals only
under explicit retention rules. Export uses selected redacted artifacts, never
an entire workspace or arbitrary model-selected file list.

## Review record

- Plan: [PLAN.md](PLAN.md).
- Workflow and authentication boundaries: [WORKFLOW.md](WORKFLOW.md).
- Implementation branch: `codex/dashboard-evidence-assistant`, local isolated
  checkout based on the public main commit recorded above.
- PR: [publication record](PR.md). The remaining items have no remote issue
  numbers and do not provision external connections or deployments.
- Verification: [RESULTS.md](RESULTS.md); validated with automated checks and synthetic browser review. Proposed
  milestones are not tested capabilities.
