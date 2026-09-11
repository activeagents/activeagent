# Release 1.5.0 branch

- Branch: `release/1.5.0`
- Base: main commit `cd65327f`
- Tag: `v1.5.0`
- Ships: `activeagent` 1.5.0 and `actionagent` 1.5.0 from one tag

## Commits

| Commit | Purpose |
|--------|---------|
| `3c697784` | Cherry-picked client-name scrub (comments and docs) |
| `68b8312d` | Completes the scrub across evals code and test fixtures |
| `6680a46d` | Version bumps and the dated changelog heading |

## Version jump

`actionagent` goes 1.3.0 -> 1.5.0, skipping 1.4. Both gems are released
together from this repository and from one tag, so carrying one version
number across both is less confusing than tracking which dashboard version
pairs with which framework. `actionagent` 1.4 does not exist. The engine's
floor on the framework (`activeagent >= 1.4`) is unchanged and still
correct: 1.5.0 satisfies it.

`activeagent` 1.4.0 -> 1.5.0 is a minor, not a patch, because it adds
`Evals::Publisher`, the runner's `around_evaluation:` and
`require_judge_scores:` hooks, and grouped YAML/JSON suite import.

## Artifacts

Built to `pkg/`, not yet pushed:

- `pkg/activeagent-1.5.0.gem` (205 KB, 189 files)
- `pkg/actionagent-1.5.0.gem` (505 KB)

Publish `activeagent` first; `actionagent` depends on it.
