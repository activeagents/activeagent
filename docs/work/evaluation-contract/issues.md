# Evaluation contract issues

## Failing task-completion scores passed

Successful tool and content checks raised the aggregate above the pass
threshold even when task completion scored 0.0 or 0.2. Task completion now
must independently meet the configured threshold. Aggregate scores remain
available, and model summaries expose `avg_task_completion` separately.

## Judge output handling

The score regex read valid JSON `9e-2` as 9 and clamped it to 1.0. Scores now
come from parsed finite JSON numbers. Current main already discarded boolean
and array tool suggestions; regression coverage protects all report formats
and invalid nested suggestion fields are now discarded too.

## Grouped catalog import

Pasted YAML suites were interpreted as lines of prompts. The parser now
accepts grouped YAML/JSON with stable scenario keys and expectations.
Dashboard imports exclude production-only questions unless explicitly
requested. Empty selections and invalid suite documents return import
errors. The core parser preserves source metadata; dashboard records store
the selected scenarios rather than the original source document.

## Correlation across replay and judging

`Runner#call` accepts an `around_evaluation` callable so hosts can establish
one context around the replay, task scoring, and judge recommendations.

## Mounted dashboard replayed its own runtime instead of the host's agent

`ActionAgent.scenario_evaluation_adapter_resolver` now lets a host dispatch
selected scenarios/models through its actual application runtime while the
engine retains scheduling, authorization, persistence, and report rendering.
The supplied owner is suitable for a background job. A registered adapter
can run an observed agent's persisted evaluation; an unregistered observed
agent remains read-only.

Host report/replay metadata now survives persistence and report
reconstruction, including stable IDs and response/judge trace references.
Incomplete adapter reports fail rather than showing an empty completed run.
