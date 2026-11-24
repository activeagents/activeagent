require "test_helper"

class ConversationScenariosTest < ActiveSupport::TestCase
  setup do
    @agent = ActionAgent::Agent.create!(name: "Issue Agent", provider: "anthropic", model: "claude-haiku-4-5",
                                        instructions: "Help with the backlog.", tools: IssueTools.tool_names)
    @context = ActionAgent::AgentContext.create!(contextable: @agent, agent_name: "IssueAgent", action_name: "ask")
  end

  test "each user message becomes a scenario expecting the tools its answer called" do
    @context.messages.create!(role: "user", content: "What is urgent?")
    @context.messages.create!(role: "tool", content: "{}", tool_name: "find_issues", tool_call_id: "t1")
    @context.messages.create!(role: "assistant", content: "Two issues.")
    @context.messages.create!(role: "user", content: "Thanks!")
    @context.messages.create!(role: "assistant", content: "Any time.")

    urgent, thanks = ConversationScenarios.new(@agent).call

    assert_equal [ "What is urgent?", { "tools" => [ "find_issues" ] } ], urgent.values_at("prompt", "expectations")
    assert_equal [ "Thanks!", {} ], thanks.values_at("prompt", "expectations")
  end

  test "the same question asked twice is one scenario, so merging again adds nothing" do
    2.times { @context.messages.create!(role: "user", content: "What is urgent?") }
    scenarios = ConversationScenarios.new(@agent).call
    evaluation = ActionAgent::Evaluation.create!(agent: @agent, name: "Real conversations", judge_kind: "llm", sample_size: 20,
                                                 criteria: [ { "key" => "response_present", "type" => "response_present" } ])

    assert_equal 1, evaluation.merge_scenarios!(scenarios)[:added].size
    assert_equal 1, evaluation.merge_scenarios!(ConversationScenarios.new(@agent).call)[:unchanged].size
  end
end
