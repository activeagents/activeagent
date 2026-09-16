# Release 1.6.0 validation

## Verification gate: CI on the base commit

The release is cut from `main` at `51c7feb7` (the #451 merge). CI is green on
that exact commit — run `34736861631`:

| Job | Result |
|---|---|
| `test (3.2, gemfiles/rails7.gemfile)` | 1978 runs, 6525 assertions, 0 failures, 0 errors, 22 skips |
| `test (3.3, gemfiles/rails8.gemfile)` | 1978 runs, 6525 assertions, 0 failures, 0 errors, 22 skips |
| `test (3.4, gemfiles/rails8.gemfile)` | 1978 runs, 6525 assertions, 0 failures, 0 errors, 22 skips |
| `test (3.4, gemfiles/railsmain.gemfile)` | 1978 runs, 6525 assertions, 0 failures, 0 errors, 22 skips |
| `Test API Gems (3.4)` | 8 runs, 18 assertions, 0 failures, 0 errors |
| `lint` | success |

`bin/lint` locally: 542 files inspected, no offenses.

`bundle exec rake build_all` succeeds and both archives pass the task's own
content assertions (`lib/active_agent.rb`; `lib/action_agent.rb`,
`config/routes.rb`, `app/assets/builds/action_agent.{js,css}`).

## Local suite: 34 errors, all environmental

A local run on Ruby 3.4.9 reports `1982 runs, 0 failures, 34 errors, 21
skips` — four more runs and 34 more errors than CI on the same commit. None
is release content. Two causes:

1. **Placeholder API keys.** `.env.test` holds placeholders (its own comment
   says CI holds the real keys), so tests that reach a live provider fail
   with `Incorrect API key provided: test-ope***-key`. This accounts for the
   `integration_test.rb` errors and several in `ruby_llm_provider_test.rb`.

2. **`gemfiles/rails8.gemfile.lock` is not committed.** `git ls-files
   gemfiles/` lists the `.gemfile` files only. CI therefore resolves
   `ruby_llm` fresh at install time, while a local checkout keeps whatever
   its untracked lock pinned — here 1.16.0, whose `RubyLLM::Message` exposes
   `tool_calls` and `input_tokens` as readers but no longer as writers.
   `test/providers/ruby_llm/ruby_llm_provider_test.rb`'s `StubProvider`
   assigns them (`msg.input_tokens = 10`, `msg.tool_calls = {...}`), so it
   raises `NoMethodError` locally and passes in CI. Same commit, same
   declared dependency, different resolution.

Cause 2 is worth fixing on its own branch — either commit the lock or adapt
the stub to construct a `Message` with those values rather than assigning
them. It is a CI/local divergence that hides real breakage, but it is not a
1.6.0 blocker and no code in this release touches it.

## Local toolchain note

`.tool-versions` says `ruby latest`, which resolves to 4.0.6 here. Rails 8.1
cannot boot on it — `bin/test` dies at `cannot load such file --
active_storage/engine` before running anything. CI tests 3.2/3.3/3.4 only.
Verify locally with `mise exec ruby@3.4.9`.

## Not verified

No host application was installed against the built 1.6.0 archives (the
1.5.2 release did do this). The gems build, contain their entry points, and
CI is green on the base commit; an end-to-end install check is still worth
doing before pushing if the owner wants the same bar as last cycle.
