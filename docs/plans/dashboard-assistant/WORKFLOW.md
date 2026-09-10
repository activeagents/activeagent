# Conversational dashboard workflow

Date: 2026-09-09. Branch: `codex/dashboard-evidence-assistant`.
Base: `1ab417d721b1d636144d0e83f38a4f0f48943dd6`.
Status: product and architecture contract; M1 is implemented and locally validated.
The implementation PR is recorded in [PR.md](PR.md); no remote issues opened.

This document expands [PLAN.md](PLAN.md). Examples are synthetic. Repository
connections, COI execution, Claude Code handoff, and GitHub checks are proposed
milestones, not features enabled by the first assistant release.

## Start with the user's question

A developer asks, “What are some good demo questions that work on main today?”
The assistant first searches the reports that the signed-in developer may read.
It returns the exact recorded question, result, model, and a link to the evidence.
It explains the evidence's age and scope before calling a question demo-ready.

An answer might be: “This question passed a historical run, but that report does
not identify a tested commit. I can evaluate the current main branch.” That
answer can offer a repository connection card. A GitHub login is unnecessary
when the existing authorized reports already answer the question.

Another developer asks, “Create an agent that explains build failures.” The
assistant asks about missing requirements through the conversation, proposes
instructions and permitted tools, and presents a draft card. **Review in
builder** carries the draft to the existing configuration/review flow. The
builder's explicit save creates the agent. A model-generated draft is not a
saved agent or an execution authorization.

The first implementation uses a configured model for this conversation and
bounded report tools. Missing provider credentials produce a Settings action
and a clear explanation; a simulated response cannot stand in for a model run.
The browser tab holds bounded conversation history. Durable workspace tasks,
streaming progress, reconnection, and cancellation across sessions are later
work.

## UI follows the current task

The model requests typed operations; the server authorizes each operation and
returns validated data. React renders known components from that data. Generated
HTML, arbitrary URLs, executable scripts, and model-supplied action names never
become UI actions.

| User intent | Useful UI | Action boundary |
|---|---|---|
| Find a working demo | Evidence cards with exact question, model, result, scope and source | Read authorized reports |
| Generate an agent | Draft instructions and selected tool cards | Review and save through the builder |
| Verify a branch | GitHub connection, repository/ref picker, run configuration | Start a run with its shown scope and budget |
| Explain a failure | Answer/tool trace, expected behavior and proposed remedy | Diagnosis alone changes no files |
| Repair an agent or tool | Workspace progress, patch, affected scenarios and regression results | Review the prepared diff before publishing |
| Use a coding session | Native handoff instructions and task context | Developer starts or accepts the handoff |

Cards carry server-issued IDs. Following an evidence link or accepting a draft
rechecks ownership; a valid ID in a previous conversation does not grant access
to another user's report. Model history and report text are untrusted input,
including any instructions found inside a repository or tool output.

## What a passing result proves

The assistant separates execution status from behavioral evidence:

| Evidence | Allowed description |
|---|---|
| Completed generation without behavioral expectations | Ran successfully; correctness was not established |
| Format or expected-tool checks passed | Passed the stated checks; inspect answer fidelity separately |
| Empty-result answer or request for missing context | Handled the recorded context; not evidence of a substantive answer |
| Explicit behavioral checks passed against known fixtures | Passed those behaviors for the recorded configuration |
| Provider, dependency or sandbox setup failed | Blocked before evaluation; not a failed model answer |
| Scenario was skipped or absent from selection | Not evaluated |
| Historical pass followed by a comparable failure | Latest comparable evidence failed; older success remains inspectable |

An LLM judge score is evidence under a rubric, not an independent fact check.
Report cards disclose the rubric, expectations, and whether the answer was
grounded in tool results or known fixture values. A list of called tool names
alone does not prove that arguments, authorization, returned records, and final
answer were correct.

The current evidence service must expose its search coverage and limits. “No
matching result was found in the searched reports” is different from “this
agent cannot do that.” Search truncation cannot silently turn into a complete
capability inventory.

### Immutable run manifest (M2)

A report must retain the inputs used by that run. Editing an agent, scenario,
tool, or rubric later must not rewrite its history. Store a versioned manifest
and integrity digest with at least:

- Repository identity, tested commit SHA, compared base SHA, ref resolved at run
  start, and any applied patch digest. Record whether checkout was clean.
- Agent identity/version, rendered instructions digest, selected tools and
  schemas, tool implementation/configuration digests, and permitted capabilities.
- Suite/scenario keys, exact prompts, expectations, selection, fixture version
  and dataset scope. Protect retained inputs under the repository's access rules.
- Provider, model identifier and revision where available, generation settings,
  judge model, rubric/version, thresholds, repetitions, and random seed where
  the provider supports one.
- Runtime image digest, dependency lock digest, runner version/identity,
  environment profile, start/end times, budget, cancellation and setup status.
- Per-case actual output, tool-call arguments/results subject to redaction,
  assertions, scores, faults, latency, usage, and artifact integrity references.

Credentials are represented by non-secret connection references, never stored in
the manifest. A trusted runner issues the manifest and result status; evaluated
repository code cannot certify its own success by writing a report file.

“Verified on current main” requires resolving main now and matching the recorded
tested SHA, along with an applicable agent, model, tools, dataset and environment.
A matching SHA is necessary but insufficient when dependencies, hosted models,
external services or fixture data changed. If main advances, retain the older
report and mark it historical. A partially recorded legacy run never gains
missing provenance by inference.

## Connect GitHub and evaluate a repository (M3)

Use a GitHub App installation with selected repositories. The dashboard host
login identifies the user; GitHub authorization establishes which installations
and repositories that user can connect. Installation identity alone does not
authorize every dashboard user to view its repositories. Recheck access on
repository selection, execution, report retrieval and publication.

The controller handles the authorization callback with session-bound state and
records only the approved installation and repository mapping. A server-side
credential broker issues installation access tokens narrowed to the selected
repository and required permissions; GitHub documents a one-hour lifetime.
Request read access for evaluation and reserve write permissions for checks or
approved publishing. See [GitHub installation authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation).

The repository/ref selector resolves a branch or PR to immutable SHAs. The run
card shows the agent, suite, fixtures, models, permitted network/tool access and
budget. Starting it queues a task with stable identity and idempotency key.
Retrying uses an explicit new attempt and preserves the failed attempt's status.

The trusted worker checks out the exact SHA in a fresh COI workspace, discovers
agents and tests under the selected policy, and executes the bounded evaluation.
[Code on Incus](https://github.com/mensfeld/code-on-incus) provides command and
prompt execution; it does not by itself establish this application-level trust
boundary. Its [restricted network mode](https://github.com/mensfeld/code-on-incus/wiki/Network-Isolation)
permits public internet access, so use a run-specific allowlist or broker where
egress must be constrained.

Repository code and dependency installation are untrusted execution. Keep the
GitHub App private key, publishing credentials and other tenants' resources
outside the worker. Fetch source through a trusted stage; provide model access
through a scoped, budgeted broker where possible. Separate fixture storage,
workspaces, caches and artifact access between tenants. Set resource limits,
timeouts and cleanup rules, and exercise cancellation during setup as well as
generation. A sandbox failure remains visible as infrastructure failure.

The engine currently ships an in-memory mock sandbox backend and a host backend
registration seam. A registered Incus name or a successful mock run is not proof
that a real COI evaluation ran. M3 requires an implemented adapter, deployed
worker and integration validation before its controls become available.

## Continue in Claude Code or a hosted worker (M4)

Offer two explicit execution choices with different credential boundaries:

1. **Native Claude Code handoff.** Prepare the task, selected checkout, failing
   scenarios and artifact references. The developer runs the unmodified Claude
   Code binary and authenticates through its native interface. The dashboard
   must not collect, store or intermediate Claude.ai tokens, or imitate the
   native login. A hosted native binary, if offered later, must preserve those
   requirements. See [Claude Code legal and compliance guidance](https://code.claude.com/docs/en/legal-and-compliance).
2. **Hosted SDK execution.** The application's worker uses its configured API
   key or supported provider credentials under the applicable billing model.
   A developer's Claude Code subscription is not automatically an application
   API credential. See [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview).

Conversation/session resume is separate from workspace persistence. Retain a
workspace snapshot or exact checkout/patch alongside the task when resuming a
coding attempt; a conversation ID does not restore files. See [Agent SDK session
management](https://code.claude.com/docs/en/agent-sdk/sessions).

The repair task proposes the smallest change supported by a failure: instructions,
an agent definition, MCP wiring, tool schema or tool implementation. It reruns
the failed scenario and relevant regressions against the prepared patch. Report
the original result and new attempt side by side, including remaining failures.
Code generation is not proof that the repair works.

## GitHub checks and publication (M5)

Verify the webhook's HMAC signature before handling it; deduplicate deliveries
and re-resolve the event's repository and head/base SHAs under the installation.
See [validating webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries).

A configured PR policy may automatically queue evaluations. Run trusted baseline
and candidate against compatible manifests and fixture snapshots. Record added,
removed, changed, skipped, regressed and improved cases separately. Infrastructure
errors cannot become green behavior checks, and an older successful run cannot
complete the check for a newer commit.

Publish a check run tied to the tested head SHA with a report link and concise
regression summary. GitHub's checks API supports check status, conclusions and
requested actions using the appropriate Checks permission. See [check runs](https://docs.github.com/en/rest/checks/runs).
The worker returns artifacts to a trusted publisher; it does not hold the
publisher's credential. Fork PR code receives no privileged credentials merely
because a maintainer repository has an installation.

A **Prepare repair** action creates a scoped task and reviewable patch. An
authorized **Open draft PR** action publishes the displayed branch, diff, tests
and description. Honor an already approved repository policy, but do not infer
publishing authority from a model suggestion or repository connection alone.
Merging and deployment remain separate actions. This implementation does not
enable that publication workflow or provision infrastructure.

## Milestone and branch record

| Milestone | Status in this branch | Completion evidence |
|---|---|---|
| M1: evidence and agent drafts | Implemented and locally validated | Scoped API and provider tests, frontend build, reviewable builder draft |
| M1.5: native product tools | Proposed | Authenticated browser connection, real builder/eval operations, optional WebMCP adapter |
| M2: reproducible reports | Proposed | Immutable manifests and provenance validation |
| M3: repository evaluation | Proposed | Verified GitHub connection and real COI integration run |
| M4: repair task and coding handoff | Proposed | Isolated repair, regression evidence, explicit credential boundary |
| M5: PR check and reviewed publication | Proposed | Webhook/check lifecycle tests and authorized draft PR flow |

Track unresolved work in [ISSUES.md](ISSUES.md) and implementation publication
in [PR.md](PR.md). Publishing this branch does not mark proposed milestones complete.
