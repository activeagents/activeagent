# Dashboard assistant implementation results

Date: 2026-09-09. Branch: `codex/dashboard-evidence-assistant`.
Base: `1ab417d721b1d636144d0e83f38a4f0f48943dd6` (public main).
Status: M1 implemented locally; automated validation and synthetic browser review passing.
PR: see [PR.md](PR.md). No remote issue, authentication integration or
infrastructure change was created by this work.

## Implemented

- **Ask ActiveAgents:** a provider-backed conversation for finding evaluation
  evidence, explaining recorded failures and preparing agent drafts. The user
  explicitly selects a provider/model and opts in to sending the current message,
  bounded history and requested authorized report excerpts to that provider.
  The server enforces opt-in before generation and report-tool callbacks.
- **Scoped evidence:** tools resolve ownership from the authenticated caller,
  return bounded results and server-issued report cards, and disclose search
  coverage. Cards use recorded replay prompts where available; current mutable
  scenario text is not substituted as historical evidence.
- **Historical pass labels:** newer comparable failures suppress older passing
  demo candidates. Recorded checks and missing provenance remain visible. A
  passing result is never labeled as current-main verification by this feature.
- **Reviewable drafts:** the assistant validates a proposed agent's instructions,
  provider, model and permitted tools. Review in builder hands it to the existing
  configuration/review flow. Saving remains explicit; a draft neither creates an
  agent nor grants tools or data access that the application does not have.
- **Execution boundaries:** host authentication, execution policy and quotas
  apply. Requests use CSRF protection; history, tool rounds and outputs are
  bounded. Missing credentials link to Settings. Provider failures return a
  generic error without exposing raw provider exception text.

## Validation

- Engine suite and affected provider/telemetry regressions: **315 tests, 1,455 assertions**,
  no failures, errors or skips.
- RuboCop: nine changed/new Ruby files, no offenses.
- Packaged frontend: JavaScript and CSS build completed successfully.
- Browser validation of the missing-provider flow: setup error shown, question
  preserved, Settings action working. The synthetic browser flow verified a real
  SDK/tool round trip, historical-evidence card with an exact report link, draft
  review across all builder steps, preserved instructions/model/empty tools, and
  conversation restoration after navigation. No agent was saved by chat.

The provider integration tests exercise actual SDK HTTP serialization and tool
round trips using synthetic HTTP fixtures with external networking blocked.
They are not live model evaluations, evidence of model answer quality, or proof
that an external provider account is configured. No live-provider successes are
claimed in this record. Logs and browser harnesses are gitignored under
`tmp/dashboard-assistant/`.

The final suite used a fresh isolated SQLite database. An initial run against
the default test database encountered leftover synthetic browser
fixture rows; the clean database run passed without a code change.

## Current limitations

Existing reports lack immutable repository, agent/tool, rubric and fixture
manifests. The assistant can explain the recorded checks and their limits, but
cannot establish correctness merely from a judge score or a successful tool
call. A report link may still show mutable current configuration; the card makes
that limitation explicit. Search is bounded and is not a complete capability
inventory.

Conversation state lives in the browser tab. Each generation disables framework
traces and provider notifications to avoid a separate unscoped evidence store.
The assistant filters message/history parameters before Rails request logging,
including rejected requests. Provider retention and host middleware that records
raw HTTP bodies still follow the host's policies. Durable tasks, reconnectable
progress and distributed cancellation are not implemented. The assistant does
not run evaluations, check out repositories, execute repairs or publish PRs.
GitHub authentication, COI execution and Claude Code session authentication are
not implemented; connection capability responses report them as unsupported.

## Follow-up review fixes

- Assistant runtime options are restricted to connection settings plus its own
  generation policy after `generate_with` merges configuration. Global, inherited
  and owner-provided MCP tools, request overrides and conversation state cannot
  enter the assistant request. Agent delegation is disabled for these turns.
- Evidence cards replace raw historical exceptions with a fixed disclosure;
  status, fault category and report links remain available. Stored reports are
  unchanged, and free-form prompts/outputs still require processing consent.
- An endpoint-scoped middleware filters message/history parameters before Rails'
  request logger and controller notifications, under any engine mount.
- Compact server-issued report references survive excerpt eviction. The final
  answer rejects evidence IDs not supplied to the model during the current turn;
  the UI keeps reference links available alongside the bounded excerpt cards.

Validation for these fixes: the dashboard engine suite passed on Ruby 3.4.5 with
**283 tests, 1,426 assertions**, no failures, errors or skips. The focused assistant
tests account for **44 tests, 358 assertions**. All eight changed/new Ruby files
passed RuboCop, and the packaged frontend build passed. A React rendering check
verified retained references under a custom mount and rejection of external URLs.

## Remaining milestones

| Milestone | Status |
|---|---|
| M1: conversational evidence and agent drafts | Implemented; automated checks and synthetic browser review passing |
| M1.5: native product tools and optional WebMCP adapter | Planned; architecture in [PRODUCT_TOOLS.md](PRODUCT_TOOLS.md) |
| M2: immutable run manifests and current-branch evidence | Planned |
| M3: GitHub repository connection and real COI execution | Planned |
| M4: repair workspace and native/hosted coding handoff | Planned |
| M5: exact-commit PR checks and reviewed publication | Planned |

See [PLAN.md](PLAN.md), [ISSUES.md](ISSUES.md) and [WORKFLOW.md](WORKFLOW.md).
The implementation and these documents use independently written generic
examples and synthetic fixtures. No private repository material is included.
