# Pages deploy: leaked WebMock stubs broke the docs build

- Branch: `fix/docs-deploy-vcr-record-mode`
- Base: main commit `b8c741d3` (the 1.6.2 merge, PR #455)
- Fix commit: `3705a33a`
- Symptom first seen: run [35161647520](https://github.com/activeagents/activeagent/actions/runs/35161647520),
  the push of the 1.6.2 merge to `main`

## Symptom

The `Deploy VitePress site to Pages` workflow failed on `main`, so the published
docs stopped updating and did not reflect the 1.6.2 release. The `build-current`
job's `Generate doc examples from tests` step exited 1 on a single error out of
2016 runs:

```
Docs::AgentsExamplesTest::UsingConcernsTest#test_demonstrates_concern_usage_with_analyze_data:
NoMethodError: undefined method 'each_key' for nil
    webmock/util/hash_validator.rb:12:in 'validate_keys'
    webmock/response.rb:80:in 'options='
    webmock/response.rb:25:in 'initialize'
    webmock/response.rb:158:in 'evaluate'
    webmock/stub_registry.rb:80:in 'evaluate_response_for_request'
    webmock/http_lib_adapters/net_http.rb:90:in 'request'
```

The error names a docs test and a cassette, so it reads as a bad or missing
cassette. It is neither.

## Two wrong hypotheses, and why

Recording both because each looked convincing and cost a cycle to rule out.

**1. `filter_sensitive_data` over an unset env var.** Commit `1ec2acac` had
already fixed exactly this error message, whose mechanism is a VCR filter whose
block returns nil. That fix is on `main`, so it was not the cause here — but it
is why the error message was familiar and initially misread as a regression of
that fix.

**2. `docs.yml` never sets `CI`.** True, and it does have real consequences:
`test_helper` derives `VCR_RECORD_MODE` from `CI` (`:none` on CI, `:once`
otherwise), and `:none` is what sets `allow_http_connections_when_no_cassette =
false`. `bin/test` also branches on `CI` to load `.env.test`. The theory was
that `:once` let a cassette miss escape as a real request. Setting `CI: true`
and rerunning the full suite still reproduced the error, which disproved it.
Worth knowing but not the bug; `docs.yml` was left unchanged.

## Root cause

`webmock/minitest` installs its stub-registry reset by aliasing `teardown` onto
`Minitest::Test` **at load time**:

```ruby
alias_method :teardown_without_webmock, :teardown
def teardown_with_webmock
  teardown_without_webmock
  WebMock.reset!
end
alias_method :teardown, :teardown_with_webmock
```

A class that later defines its own `teardown` overrides that alias. Without
`super`, `WebMock.reset!` silently never runs for that class.

`DashboardAssistantServiceTest` did exactly that. Every test in it registers a
`stub_request` against the provider, and four do so as a `to_return` block over
a fixed list:

```ruby
responses = [ ..., ..., ... ]              # three entries
stub_request(:post, "https://api.openai.com/v1/responses")
  .to_return { |request| requests << JSON.parse(request.body); responses.shift }
```

`responses.shift` returns **nil** once the list is exhausted. So:

1. The stubs outlive the file, because the reset was suppressed.
2. A later test requesting the same URL matches a leaked stub. VCR's webmock
   hook sees a registered stub, classifies the request `:externally_stubbed`,
   and returns nil from `on_externally_stubbed_request` to hand control to
   WebMock — the documented way to say "not mine".
3. WebMock's global-stub path calls the leaked responder, gets nil from an
   exhausted `shift`, and constructs `Response.new(nil)`, which dies in
   `validate_keys`.

The crash therefore surfaces inside WebMock's own response construction, in
whichever unrelated test happened to draw an exhausted stub.

Confirmed by instrumenting `WebMock::DynamicResponse#evaluate` to report a nil
responder result. At the failure it printed the responder as a `Proc` from
`dashboard_assistant_service_test.rb:329`, with the cassette
`docs/agents_examples/concerns_analyze_data` active and ten stubs still
registered — all leaked from that file.

## Why it was seed-dependent

Which test pays depends on minitest's run order, so the failure follows the
seed. Full suite, `CI=true bin/test` on `gemfiles/rails8.gemfile`, 2016 runs:

| seed | before | after |
|------|--------|-------|
| 1 | 0 errors | 0 errors |
| 4242 | 0 errors | 0 errors |
| 27111 (the failing deploy) | **1 error** | 0 errors |
| 55555 | not run | 0 errors |
| 99999 | **1 error** | 0 errors |

`ci.yml`'s ordering stayed green throughout, which is why only the docs job ever
went red and the bug looked like a docs problem.

## Fix

One line: `super` at the end of that `teardown`, restoring the reset for this
class so its stubs cannot escape the test that registered them.

Fifteen other classes also define `teardown` without `super`. They are left
alone deliberately: the crash needs a responder that can return nil, and none of
them registers one. Worth revisiting as its own cleanup, not smuggled into a
deploy fix.

## Verification

- Full suite, 2016 runs, 0 failures / 0 errors / 22 skips at seeds 1, 4242,
  27111, 55555 and 99999.
- Teardown chain asserted to reach `Minitest::Test`, where webmock's reset
  lives: `[DashboardAssistantServiceTest, Minitest::Test]`.
- `npm run docs:build` completes, and generated `versions.json` resolves the
  current version to **1.6.2**.
- RuboCop clean.

## Note on the release itself

`activeagent` and `actionagent` 1.6.2 are both live on RubyGems. The
`release.yml` `publish` job failed on the tag with `No trusted publisher
configured for this workflow found on https://rubygems.org`, and the gems were
pushed by hand. Configuring a trusted publisher on rubygems.org for both gem
names — repo `activeagents/activeagent`, workflow `release.yml` — would let
future tags publish unattended. Unrelated to this fix, tracked here so it is
not lost.
