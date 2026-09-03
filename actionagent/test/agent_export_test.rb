# frozen_string_literal: true

require "test_helper"

# The Code tab and GET /api/agents/:id/export advertise "Generated Ruby code
# for this agent". It has to parse, and it has to name the class the agent's
# traces are correlated on (#375).
class AgentExportTest < ActiveSupport::TestCase
  def setup
    ActionAgent::Agent.delete_all
  end

  def create_agent(**attributes)
    ActionAgent::Agent.create!({ provider: "openai", model: "gpt-4o-mini" }.merge(attributes))
  end

  def parses?(code)
    RubyVM::AbstractSyntaxTree.parse(code)
    true
  rescue SyntaxError
    false
  end

  test "an agent named with spaces exports a class that parses" do
    agent = create_agent(name: "Review Probe Agent", instructions: "Be brief.\nBe kind.")

    code = agent.to_agent_class_code

    assert parses?(code), "generated code does not parse:\n#{code}"
    assert_match(/\Aclass ReviewProbeAgent < ApplicationAgent/, code)
    assert_equal agent.telemetry_agent_class, code[/\Aclass (\w+)/, 1]
  end

  test "instructions produce exactly one prompt call" do
    agent = create_agent(name: "Helper", instructions: "Be brief.")

    code = agent.to_agent_class_code

    assert parses?(code)
    assert_equal 1, code.scan(/^\s*prompt\b/).size, "expected one prompt call:\n#{code}"
    assert_includes code, "prompt instructions: <<~INSTRUCTIONS"
    assert_includes code, "Be brief."
  end

  test "no instructions produce a bare prompt call" do
    agent = create_agent(name: "Helper")

    code = agent.to_agent_class_code

    assert parses?(code)
    assert_equal 1, code.scan(/^\s*prompt\b/).size
    assert_not_includes code, "instructions:"
  end

  test "an observed agent's exported class is its reported class, not doubled" do
    agent = create_agent(name: "Telemetry Only", agent_class_name: "TelemetryOnlyAgent", status: :observed)

    code = agent.to_agent_class_code

    assert parses?(code)
    assert_match(/\Aclass TelemetryOnlyAgent < ApplicationAgent/, code)
    assert_not_includes code, "TelemetryOnlyAgentAgent"
  end
end
