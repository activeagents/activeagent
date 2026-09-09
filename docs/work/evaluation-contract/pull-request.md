# Draft pull request: preserve evaluation scoring and import contracts

An expected tool call could turn an answer graded 0.2 into a passing
evaluation. Require task completion to meet the run threshold separately,
parse judge scores as JSON numbers, and tolerate malformed recommendation
fields across report formats.

Grouped YAML/JSON imports retain scenario expectations and keys.
Dashboard create/replace imports select production-only questions only
when `include_production_only` is true and reject empty or invalid imports.
An optional `around_evaluation` callback lets hosts correlate replay and
judge calls. Existing aggregate report scores remain available alongside
`avg_task_completion`.

Validation: 135 core/dashboard tests / 840 assertions; the combined run with
publication tests passes 142 tests / 867 assertions. Eleven changed Ruby files
lint clean.
This change uses only synthetic public catalog data.

The mounted dashboard also supports a host-provided scenario evaluation
adapter. It receives selected scenarios/models and the evaluation owner,
persists results via the engine callback, and returns the same report type.
Run and replay metadata survive reconstruction without new schema columns.
Observed agents run only evaluations explicitly routed to a host adapter.
The expanded regression suite passes 176 tests and 1,009 assertions.

Catalog refresh now preserves historical prompts, expectations, notes, and
judge labels in both reports and the result matrix. Dashboard links can open
a specified evaluation or saved report without depending on index ordering.
This adds 73 mounted-engine checks / 351 assertions and five frontend checks
covering historical evidence, current reruns, and scoped links.
