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
