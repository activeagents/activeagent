# frozen_string_literal: true

# Evals are ordinary tests under test/evals that each call a model, so
# `rails test` skips them (ActiveAgent::Evals::TestCase checks EVALS) and this
# task runs them: it switches EVALS on and hands test/evals to the same runner
# `rails test` uses, so seeds, parallel workers and reporters behave the same.
#
#   bin/rails test:evals
#   bin/rails test:evals TEST=test/evals/support_agent_test.rb
#   bin/rails test:evals TESTOPTS="--seed 1234 -v"
#   EVALS=1 bin/rails test test/evals/support_agent_test.rb:12   # one eval, through rails test
#   EVALS=1 bin/rails test                                       # the whole suite, evals included
namespace :test do
  desc "Run the agent evals in test/evals (switches EVALS on); TEST=path narrows, TESTOPTS passes options"
  task :evals do
    require "active_agent/evals/test_helper"
    require "rails/test_unit/runner"

    paths = Array(ENV["TEST"]).map(&:to_s).reject(&:empty?).presence || [ "test/evals" ]
    missing = paths.reject { |path| File.exist?(path) }
    abort "No evals found: #{missing.join(", ")} does not exist. Evals are tests under test/evals." if missing.any?

    ENV[ActiveAgent::Evals::TestHelper::ENV_KEY] = "1"
    runner = Rails::TestUnit::Runner
    runner.respond_to?(:run_from_rake) ? runner.run_from_rake("test", paths) : runner.rake_run(paths)
  end
end
