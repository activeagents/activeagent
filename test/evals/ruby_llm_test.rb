# frozen_string_literal: true

require "test_helper"

# Runs the RubyLLM glue's cases (support/ruby_llm_glue_cases.rb) in a process
# of their own. They load the real ruby_llm gem, and loading it into this one
# would take the place of the stand-ins the RubyLLM provider's tests define
# only while the gem is absent (test/providers/ruby_llm/ruby_llm_provider_test.rb),
# turning those tests against the real gem.
class EvalsRubyLLMTest < ActiveSupport::TestCase
  CASES = File.expand_path("support/ruby_llm_glue_cases.rb", __dir__)
  LIB = File.expand_path("../../lib", __dir__)
  TEST = File.expand_path("..", __dir__)

  test "the RubyLLM judge and replay cases pass" do
    output = IO.popen([ RbConfig.ruby, "-I#{LIB}", "-I#{TEST}", CASES ], err: %i[child out], &:read)
    status = $?

    assert status.success?, output
    assert_match(/^[1-9]\d* runs, \d+ assertions, 0 failures, 0 errors/, output, "no case ran:\n#{output}")
  end
end
