# Conversational dashboard workspace

Date: 2026-09-09. Branch: `codex/dashboard-evidence-assistant`.
Base: `1ab417d721b1d636144d0e83f38a4f0f48943dd6` (public main).
Status: M1 implemented locally; validated with automated checks and synthetic browser review.

## Goal

Let a developer ask the dashboard what its agents can do, inspect the evaluation
evidence, and prepare an agent through conversation. Extend that same task into
repository evaluation, sandbox repair, and a reviewed pull request.

## First implementation

1. Add an owner-scoped evaluation evidence service. Return recorded prompts and
   result IDs, never reinterpret a mutable current scenario as historical input.
   Newer failures supersede older passes. Expose limited search coverage and
   distinguish historical passes from current-branch verification.
2. Add a provider-backed dashboard assistant with read-only report tools and
   validated agent-draft proposals. Reuse host authentication, provider credentials,
   execution settings, and quotas. Do not run repository commands or create agents
   merely because a model proposed them. Bound tool calls, history, and results.
3. Add an Assistant view with conversation, server-issued evidence cards, and a
   Review in builder action. Reuse the builder's configuration/review/save flow.
   Missing model credentials produce a Settings action; no simulated model answer.
4. Test scoped access, historical prompt fidelity, superseded passes, weak checks,
   model tool round trips, invalid proposals, CSRF, and the built frontend.

The user explicitly selects a provider and model and opts in before sending a
message, bounded history or authorized report excerpts to that provider. The
server enforces this requirement for generation and report-tool callbacks.
Provider integration tests exercise the real SDK HTTP paths with synthetic
fixtures and blocked external networking; they do not establish live model
answer quality. Validation results are recorded in [RESULTS.md](RESULTS.md).

The first conversation keeps bounded history in the browser tab. It does not reuse
an agent's shared context across unrelated users or tasks. Durable task histories,
streamed jobs, and distributed cancellation belong to the next workspace milestone.

## Repository evaluation and repair milestones

- **M1 — Evidence and drafts:** conversational report discovery, cited historical
  demo questions, agent draft review. Implemented; validated with automated checks and synthetic browser review.
- **M1.5 — Native product tools:** shared capability registry, authenticated
  browser connection, optional WebMCP adapter, and real builder/eval operations.
  Planned in [PRODUCT_TOOLS.md](PRODUCT_TOOLS.md), without a Tidewave runtime
  dependency. Sandbox integration remains part of M3.
- **M2 — Reproducible reports:** immutable scenario/agent/tool/suite/fixture
  snapshots plus repository ID, tested SHA, base SHA, runtime and trusted runner
  identity. A current-main claim requires a freshly resolved main SHA match.
- **M3 — Connect and evaluate:** GitHub App installation, repository/branch picker,
  exact-SHA checkout in a COI worker, capability discovery, bounded run, report.
- **M4 — Repair task:** explain a failing scenario, prepare a scoped workspace,
  generate agent/MCP/tool changes, rerun failed cases and regressions, review diff.
- **M5 — GitHub check:** webhook verification/deduplication, pinned head/base
  comparison, check result linked to the report, explicit PR publishing action.

## Product behavior

M1 uses authorized existing reports after provider/data opt-in and labels every
demo candidate as a historical pass. It cannot verify a branch, run an evaluation,
or connect GitHub, COI or a Claude Code session. Missing connection capabilities
are reported as unsupported.

For the proposed repository workflow, ask for a GitHub connection only when the
requested repository/current-branch evidence is missing. A question should
produce the smallest useful UI: evidence cards, an agent draft, a repository/ref
selector, an evaluation progress card, or a proposed patch with test results.

Treat passing shape checks, behavioral checks, empty-result responses, infrastructure
errors, and untested scenarios separately. A failed provider setup is not a failed
answer. A historical pass is not proof of current main behavior.

## Scope and privacy

This public checkout contains only generic examples and synthetic tests. No client
source, reports, records, screenshots, or private catalog content is copied here.
No credentials are collected in prompts. Publishing this implementation PR does
not create a GitHub installation, customer connection, or infrastructure resource.

## Branch and PR status

See [PR.md](PR.md) for the implementation branch and publication record,
[RESULTS.md](RESULTS.md) for
implementation scope, limitations and final validation status, and
[ISSUES.md](ISSUES.md) for the remaining milestones. M1.5 and M2–M5 remain planned.
