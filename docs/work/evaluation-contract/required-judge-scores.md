# Required judge scores

Applications displaying a run as an LLM evaluation can pass
`require_judge_scores: true` to `ActiveAgent::Evals::Runner`. An otherwise
passing result fails with `judge_unavailable` when a requested task-completion
or explicit `llm_judge` criterion has no usable grade. Its numeric grade remains
nil; rule scores stay visible and do not imply that the judge assessed quality.

This applies to provider errors, malformed responses, and a missing judge for
an explicitly requested LLM criterion. Rules-only evaluations are unchanged.
The default remains false for applications relying on the existing rules
fallback. Mechanical replay/tool/content failures retain their own diagnosis.

Validation: 32 runner/diagnosis tests, 163 assertions pass, including both error
and malformed-score cases, explicit criteria, and a rules-only control.
