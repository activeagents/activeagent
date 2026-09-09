# Evaluation contract milestones

- [x] Reproduce task-completion false passes with synthetic expectations.
- [x] Require task completion to pass independently of tool/content scores.
- [x] Parse finite JSON scores and verify malformed recommendations cannot abort reports.
- [x] Import grouped YAML/JSON and enforce production selection through the dashboard API.
- [x] Add a context callback spanning replay and judging.
- [x] Run core evaluation and dashboard scenario regression tests.
- [x] Run lint on changed Ruby files and check patch whitespace.

Validation on Ruby 4.0.2: 135 core/dashboard tests, 840 assertions, no failures,
errors, or skips. The combined run including report publication coverage
passed 142 tests and 867 assertions. Eleven changed Ruby files passed RuboCop.
Test and lint logs are in
the ignored `tmp/evaluation-contract/` directory.

Additional mounted-host adapter validation: 176 tests, 1,009 assertions,
zero failures/errors/skips; seven changed Ruby files lint clean. Coverage
includes two-model host replay, actual owner and judge configuration delivery,
selection, metadata/report reconstruction, partial failure retention,
default-runtime fallback, and the observed-agent API gate. Logs are under
`tmp/host-evaluation-adapter/`.

Historical catalog validation: 73 mounted-engine tests / 351 assertions and
five Node frontend tests passed. Four changed Ruby files passed lint. The
regression changes a catalog prompt, expected tool, notes, group, ordering,
and judge after a run and verifies the old report remains unchanged while a
new run uses the refreshed question. Frontend tests cover snapshot matrix
rows and authorized detail lookup for links outside the index page. Logs are
under `tmp/scenario-history/`.

Observed-agent boundary validation: 67 tests / 326 assertions passed,
covering mutation/restore refusal, direct and queued execution refusal,
explicit executable duplicates, and continued host-adapter evaluation access.
Four changed Ruby files passed lint. Logs are under
`tmp/observed-agent-guards/`.
