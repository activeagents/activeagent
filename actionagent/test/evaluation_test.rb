# frozen_string_literal: true

require "test_helper"

# MySQL cannot give a JSON column a default, so an evaluation saved there
# without config or criteria reads them back as nil. The readers answer with
# the empty value the column default supplies on other databases. The test
# database honours that default, so the nil is assigned rather than persisted.
class ActionAgentEvaluationTest < ActiveSupport::TestCase
  test "a nil config reads as empty and names no comparison models" do
    evaluation = ActionAgent::Evaluation.new(config: nil)

    assert_equal({}, evaluation.config)
    assert_equal [], evaluation.compare_models
  end

  test "nil criteria read as empty" do
    evaluation = ActionAgent::Evaluation.new(criteria: nil)

    assert_equal [], evaluation.criteria
    assert_equal [], evaluation.llm_criteria
  end
end
