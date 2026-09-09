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
