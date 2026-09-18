# frozen_string_literal: true

require "test_helper"

# The dummy app's test process has the whole framework loaded, so this check
# runs out of process.
class EvalsStandaloneLoadTest < ActiveSupport::TestCase
  SCRIPT = File.expand_path("support/standalone_correlation_script.rb", __dir__)
  LIB = File.expand_path("../../lib", __dir__)

  def test_the_evaluation_module_and_a_correlated_run_load_without_the_framework
    output = IO.popen([ RbConfig.ruby, "-I#{LIB}", SCRIPT ], err: %i[child out], &:read)

    assert_equal "ok", output.strip, output
  end
end
