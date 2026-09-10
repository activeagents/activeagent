# Draft pull request: preserve evaluation scoring and report contracts

An answer graded 0.2 could pass when tool and content checks raised its
aggregate score. Task completion now must meet the threshold independently.
Judge scores use finite JSON numbers, malformed recommendations cannot abort
reports, and optional strict judge scoring reports unavailable grades as a
failure. An `around_evaluation` callback supports correlation across replay
and judging.

Grouped YAML/JSON imports retain scenario keys and expectations, with explicit
production-only selection. Mounted evaluations can dispatch selected scenarios
and models through a host-owned runtime using the actual evaluation owner.
Run/result metadata and trace IDs survive persistence. Scenario and judge
snapshots preserve historical evidence after a catalog refresh; dashboard
links open the requested evaluation or saved report. Observed agents cannot
bypass the host adapter through configuration changes or direct/queued
execution; explicit duplicates remain executable drafts.

A generic Publisher sends saved reports in the versioned collector envelope
with bounded delivery, validated receipts, and stable run IDs for retries.
Reconstructed JSON, Markdown, and HTML retain their recorded judge identity.

Validation:

- 246 core/engine tests, 1,336 assertions; zero failures/errors/skips.
- Five frontend tests; production JS/CSS rebuild matches committed assets.
- Separate synthetic cross-repository contract smoke: one test, 28 assertions,
  validating replay → Publisher → hosted importer payload shape and saved retry.
- Changed Ruby files pass lint; patch whitespace checks pass.

The contract smoke uses mocked HTTP and does not exercise live providers,
collector authentication, or database persistence. Added fixtures use generic
synthetic data. Logs remain in ignored `tmp/` directories.
