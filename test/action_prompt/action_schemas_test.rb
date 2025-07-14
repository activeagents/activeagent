require "test_helper"

class DummyAgent < ApplicationAgent
  def foo
    prompt
  end

  def method_name(*) = :foo
end

class ActionSchemasTest < ActiveSupport::TestCase
  test "skip missing json templates" do
    agent = DummyAgent.new

    assert_nothing_raised { agent.action_schemas }
    assert_equal [], agent.action_schemas
  end
end
