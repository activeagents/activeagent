---
title: Releasing & Cross-Repo Testing
description: How activeagent, actionagent and solid_agent are tested together and published — the integration suite, what it guards, and the order releases go out in.
---
# {{ $frontmatter.title }}

Three gems ship from two repositories, and they depend on each other in one
direction:

```
activeagent  ←  actionagent   (the dashboard engine, same repo)
activeagent  ←  solid_agent   (persistence, its own repo)
             ←  actionagent depends on solid_agent too
```

Each has its own suite, and each suite can be green while the combination a
user installs is broken. Two things guard against that: a cross-repo
integration suite, and a release order.

## The integration suite

`test/integration/solid_agent/` in the activeagent repository runs both gems
together inside the dummy Rails app, against the models
`rails generate solid_agent:install` writes — conversation persistence,
memory hand-offs, run records, the tool cache, and the version constraints
themselves. Every generation goes through the [mock provider](/providers/mock),
so it is deterministic and free.

Run it locally against a solid_agent checkout:

```bash
SOLID_AGENT_PATH=../solid_agent \
  BUNDLE_GEMFILE=gemfiles/solid_agent_main.gemfile \
  SOLID_AGENT_STRICT=1 \
  bin/test test/integration/solid_agent/*_test.rb \
           actionagent/test/agent_execution_service_test.rb
```

Or against solid_agent's main branch, with no checkout:

```bash
BUNDLE_GEMFILE=gemfiles/solid_agent_main.gemfile bin/test test/integration/solid_agent/*_test.rb
```

`gemfiles/solid_agent_main.gemfile` takes `SOLID_AGENT_PATH` (a local
checkout) or `SOLID_AGENT_REF` (a branch, tag or SHA).

### Two configurations, on purpose

| Configuration | Bundle | Meaning |
|---------------|--------|---------|
| **source** | solid_agent main, `SOLID_AGENT_STRICT=1` | What the repositories are developing toward. Must be green. |
| **released** | whatever Bundler resolves from RubyGems | What users install today. |

A test declares what it needs — `requires_solid_agent "SolidAgent::HasMemory"`,
or a `requires_solid_agent_capability` block for a method signature — and
**skips** when the resolved gem can't do it, printing the reason. Under
`SOLID_AGENT_STRICT=1` those skips become failures.

So the released run never fails for merely being behind; its skip list is
the report of how far behind it is, and that list is the cue to cut a
solid_agent release.

### What it catches

Real breakage found the day the suite was written:

- `has_context`'s auto-context keyword was renamed `contextable:` →
  `contextual:` between solid_agent 0.1 and 0.2. The dashboard passed the
  old one, so every run against solid_agent main died with
  `ArgumentError: unknown keyword`. Both repositories' suites were green.
- `ActionAgent::AgentToolbox`'s fallback cache key — the one used when
  `SolidAgent::ToolCache` is absent — hashed its arguments differently from
  ToolCache itself, so upgrading solid_agent silently invalidated every
  cached tool result.

Both are the same shape: a seam neither repository owns alone.

## Where it runs

| Trigger | Where | Runs |
|---------|-------|------|
| Pull request, push to main | activeagent `ci.yml` | Both configurations |
| Pull request, push to main | solid_agent `ci.yml` | That working tree against activeagent main *and* its latest release tag |
| Nightly | both repositories | Same, so drift surfaces without a push |
| `repository_dispatch` | activeagent `integration.yml` | Lets solid_agent's CI trigger a run with a specific ref |
| Before publishing | both `release.yml` files | Publishing waits on it |

## Releasing

Both repositories publish on a `v*` tag via RubyGems trusted publishing
(OIDC — no stored API key), and both gate the publish job on the
integration suite.

**Order matters.** A gem cannot be bundled until everything it depends on is
on RubyGems:

1. `activeagent` — the framework, depended on by both others
2. `solid_agent` — depends on activeagent
3. `actionagent` — depends on both (published from the activeagent repo's
   release workflow, after the framework, by the same tag)

`rake build_all` in the activeagent repo builds both of its gems and asserts
each archive actually contains its entry point — a gem that resolves and
then dies on `require` is the failure that guards against. The publish step
skips any version already on RubyGems, so the two gems in that repo can
share a tag while versioning independently.

### Raising a dependency floor

When one gem starts requiring an API the other only just added, the floor in
the gemspec has to move — and the release order above means the dependency
ships **first**. Until it does, prefer feature detection over a floor bump:
`ActionAgent.solid_agent_auto_context_keyword` is the worked example, and
`test/integration/solid_agent/compatibility_test.rb` asserts the detection
still matches the installed gem.

## See also

- [Documentation](/contributing/documentation) — how docs examples stay tested
- [Testing](/framework/testing) — testing your own agents
- [SolidAgent](/solid_agent) — what the persistence gem provides
