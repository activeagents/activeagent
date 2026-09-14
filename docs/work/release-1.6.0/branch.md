# Release 1.6.0 branch

- Branch: `release/1.6.0`
- Base: main commit `51c7feb7`
- Tag: `v1.6.0` (not yet pushed)
- Ships: `activeagent` 1.6.0 and `actionagent` 1.6.0 from one tag

## Commits

| Commit | Purpose |
|--------|---------|
| _(this branch)_ | Version bumps, the dated 1.6.0 changelog heading, and these release notes |

## Version jump

`activeagent` and `actionagent` both go 1.5.2 -> 1.6.0. A minor, not a
patch: the cycle adds `ActiveAgent::Base#current_user` and the `as(...)`
caller seam, `SchemaTools.define`/`undefine` with a per-model registry, the
`active_agent:schema_tools` generator, schema tools served over the MCP
facade, caller inheritance through `delegate_to`, and the
`ungrounded_answer` evaluation fault. That is new public surface in both
gems.

1.5.2 shipped the whole SchemaTools feature as a patch, so the repository
has precedent either way; 1.6.0 is the owner's call for this cycle, made
because seven new APIs is more surface than a patch number advertises.

The engine's floor on the framework (`activeagent >= 1.4`) is unchanged and
still correct: 1.6.0 satisfies it. `activeagents-telemetry` stays at
`~> 0.1`; nothing in this cycle calls a 0.3-only API, and `~> 0.1` already
resolves the published 0.3.0.

## Behaviour changes worth calling out

- `tools_succeeded` is awarded only for a tool the scenario expected. Suites
  that were scoring wrong-tool runs as partial successes will report lower.
- `actor:` is stripped from tool arguments and from `params[params][actor]`,
  so the caller cannot be named by the model or by a client.

## Artifacts

Built to `pkg/` with `bundle exec rake build_all`, **not pushed**:

- `pkg/activeagent-1.6.0.gem` (220 KB, 194 files)
- `pkg/actionagent-1.6.0.gem` (512 KB, 111 files)

Publish `activeagent` first; `actionagent` depends on it.

## Publishing

Tag-driven publishing does not currently work in this repository — see
`validation.md`. Every `release.yml` run to date has failed at
`No trusted publisher configured for this workflow found on rubygems.org`,
which is why 1.5.1 and 1.5.2 have no tags yet are on RubyGems. The owner
publishes these two archives by hand.
