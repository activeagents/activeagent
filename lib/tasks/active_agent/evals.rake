# frozen_string_literal: true

# Evals live in test/evals in files ending in _eval.rb. `rails test` collects
# only *_test.rb, so they never run with the suite; this task runs them through
# the same runner, so seeds, parallel workers and reporters behave the same.
#
#   bin/rails active_agent:evals
#   EVALS=test/evals/support_agent_eval.rb bin/rails active_agent:evals
#   EVALS=test/evals/orders bin/rails active_agent:evals
#   TESTOPTS="--seed 1234 -v" bin/rails active_agent:evals
namespace :active_agent do
  desc "Run the agent evals in test/evals (*_eval.rb); EVALS=path-or-glob narrows, TESTOPTS passes options"
  task :evals do
    require "active_agent/evals/test_helper"
    require "rails/test_unit/runner"

    files = ActiveAgent::Evals::TestHelper.files(ENV["EVALS"])
    if files.empty?
      where = ENV["EVALS"].presence || "test/evals"
      abort "No evals found under #{where}. Evals live in test/evals and their files end in _eval.rb."
    end

    runner = Rails::TestUnit::Runner
    runner.respond_to?(:run_from_rake) ? runner.run_from_rake("test", files) : runner.rake_run(files)
  end
end
