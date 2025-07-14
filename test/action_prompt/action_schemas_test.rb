require "test_helper"

class DummyAgent < ApplicationAgent
  def foo
    prompt
  end
end

class ActionSchemasTest < ActiveSupport::TestCase
  test "skip missing json templates" do
    agent = DummyAgent.new

    assert_nothing_raised do
      schemas = agent.action_schemas
      assert_equal [], schemas
    end
  end
end
