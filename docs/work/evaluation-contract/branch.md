# Evaluation contract branch

- Branch: `codex/evaluation-contract-fixes`
- Base: main commit `1ab417d7`
- Scope: evaluation scoring, judge parsing, catalog import, and a host context callback
- Public fixtures: a synthetic order-support catalog only

The existing report structure is retained. Model summaries add
`avg_task_completion`. `around_evaluation` is optional, and the core parser
continues to include production-only entries by default; dashboard import
selection defaults to excluding them.
