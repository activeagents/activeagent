# frozen_string_literal: true

require "test_helper"

# The dummy app's test process has the whole framework loaded, so this check
# runs out of process.
class EvalsStandaloneLoadTest < ActiveSupport::TestCase
  SCRIPT = File.expand_path("support/standalone_correlation_script.rb", __dir__)
  RUBY_LLM_SCRIPT = File.expand_path("support/standalone_ruby_llm_script.rb", __dir__)
  LIB = File.expand_path("../../lib", __dir__)

  def test_the_evaluation_module_and_a_correlated_run_load_without_the_framework
    assert_equal "ok", run_standalone(SCRIPT)
  end

  def test_the_ruby_llm_glue_is_an_opt_in_require_on_top_of_the_module
    assert_equal "ok", run_standalone(RUBY_LLM_SCRIPT)
  end

  private

  def run_standalone(script)
    output = IO.popen([ RbConfig.ruby, "-I#{LIB}", script ], err: %i[child out], &:read)
    output.strip.tap { |result| assert_equal "ok", result, output }
  end
end
