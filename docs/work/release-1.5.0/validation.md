# Release 1.5.0 validation

## Test suite

Run as CI runs it, via `bin/test` against `gemfiles/rails8.gemfile`:

```
1842 runs, 5846 assertions, 1 failures, 42 errors, 42 skips
```

The 1 failure and 42 errors are **pre-existing and unrelated to this
release**. This was established by stashing the release changes and running
the same suite on the untouched base commit, which produced an identical
count. They are concentrated in the OpenRouter and OpenAI integration tests
(VCR cassette and API-client territory) plus `RunnerWorkbenchTest`; nothing
in the evals paths this release touches.

## Lint

`bin/rubocop` — 530 files inspected, no offenses.

## Frontend

`npm test` in `actionagent/frontend` — 8 tests, 8 pass.

The committed dashboard assets in `actionagent/app/assets/builds/` were
rebuilt from source (`npm ci && npm run build`) and came out byte-identical
to what is committed, so the gem ships a dashboard matching its sources.

## Gem contents

Both archives were unpacked and checked for the files the Rakefile's
`build_all` guards on — the failure mode being a gem that installs and
resolves but dies on `require`:

- `activeagent`: `lib/active_agent.rb`
- `actionagent`: `lib/action_agent.rb`, `config/routes.rb`,
  `app/assets/builds/action_agent.js`, `app/assets/builds/action_agent.css`

`actionagent` contains no `lib/active_agent*` — the gemspec's `Dir.chdir`
guard against sweeping up the framework tree held.

Resolution check: `actionagent` 1.5.0 requires `activeagent >= 1.4, < 2`,
satisfied by 1.5.0. Both declare `required_ruby_version >= 3.2.0`.

## Environment notes

Two local-only obstacles, neither affecting the release:

- The dummy app's `config/master.key` did not decrypt its
  `credentials.yml.enc`. CI supplies `RAILS_MASTER_KEY` as a secret. A
  throwaway pair was generated to boot the suite and the committed files
  were restored afterwards — verified by checksum.
- The root `Gemfile` bundle lacks `sqlite3` for the local Ruby 4.0.6, so
  the suite must be run with `BUNDLE_GEMFILE` pointed at
  `gemfiles/rails8.gemfile` (an absolute path — `bin/test` sets it with
  `||=`, and the Rakefile's `chdir` breaks a relative one).
