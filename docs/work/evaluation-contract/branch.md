# Evaluation contract branch

- Branch: `codex/evaluation-contract-fixes`
- Base: main commit `1ab417d7`
- Scope: evaluation scoring, judge parsing, catalog import, host adapters,
  report publication, immutable report history, and observed-agent boundaries
- Public fixtures: a synthetic order-support catalog only

The existing report structure is retained. Model summaries add
`avg_task_completion`. `around_evaluation` is optional, and the core parser
continues to include production-only entries by default; dashboard import
selection defaults to excluding them.

Final validation covers the core evaluation library and mounted dashboard's
evaluation, execution, API, and engine integration paths. The synthetic
publisher/importer contract smoke does not contact providers or write to a
database. The full unrelated application/provider suite was not rerun.
