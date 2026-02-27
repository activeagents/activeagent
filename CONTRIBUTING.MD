## Contributing to Active Agent

Thanks for your interest in improving Active Agent! This guide covers the basics for setting up your environment, running tests, linting, and doing a quick local verification that things work.

### Prerequisites
- Ruby with Bundler installed
- Google Chrome/Chromium (recommended for system tests via Cuprite)

### Setup
git clone https://github.com/activeagents/activeagent.git
cd activeagent
bundle install

- Full suite:
  bin/test
  # or
  bundle exec rake test
  - Single file:
 
  ruby -Itest test/generation_test.rb

- Tests use Rails’ plugin test runner and a bundled dummy app under `test/dummy`.
- External API calls are recorded with VCR, so you shouldn’t need API keys to run the suite.

### Linting
- bin/lint          # check
- bin/lint --fix    # safe auto-correct
- bin/lint -A       # auto-correct including unsafe### Quick local verification

### Making changes
1. Create a feature branch.
2. Add tests for your change.
3. Run `bin/test` and `bin/lint` until both pass cleanly.
4. Open a pull request with a clear description of the change and motivation.

### Recording or updating VCR cassettes (optional)
If you need to re-record HTTP interactions for specific tests, set the necessary API keys in your environment and run only those tests. Please avoid committing sensitive data; VCR cassettes should only contain sanitized request/response data.

### Community and support
- Documentation: https://docs.activeagents.ai
- Issues: https://github.com/activeagents/activeagent/issues
- Discord: https://discord.com/invite/JRUxkkHKmh

We appreciate your contributions—thank you!