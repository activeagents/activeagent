require "test_helper"

class SolidAgent::DocumentationExamplesTest < ActiveSupport::TestCase
  # region test-agent
  class TestAgent < ActiveAgent::Base
    include SolidAgent::Persistable  # That's it! Full persistence enabled
    
    def analyze
      prompt
    end
  end
  # endregion test-agent
  
  # region test-automatic-registration
  test "automatically registers agent on first use" do
    agent = TestAgent.new
    
    assert_difference "SolidAgent::Models::Agent.count", 1 do
      agent.analyze
    end
    
    agent_record = SolidAgent::Models::Agent.last
    assert_equal "SolidAgent::DocumentationExamplesTest::TestAgent", agent_record.class_name
    assert_equal "active", agent_record.status
    
    doc_example_output(agent_record)
  end
  # endregion test-automatic-registration
  
  # region persistence-example
  test "complete persistence example" do
    agent = TestAgent.new
    
    # Everything is automatically tracked
    response = agent.generate(prompt: "Analyze Ruby performance")
    
    # Check what was persisted
    context = SolidAgent::Models::PromptContext.last
    assert_equal "runtime", context.context_type
    
    generation = SolidAgent::Models::Generation.last
    assert_equal "openai", generation.provider
    
    doc_example_output({
      context: context.attributes,
      generation: generation.attributes,
      messages: context.messages.map(&:attributes)
    })
  end
  # endregion persistence-example
  
  # region cycle-tracking
  test "tracks prompt generation cycles" do
    cycle = SolidAgent::Models::PromptGenerationCycle.create!(
      contextual: User.first,
      agent: SolidAgent::Models::Agent.register(TestAgent),
      status: "prompting"
    )
    
    # Track prompt construction
    cycle.track_prompt_construction do
      # Prompt building happens here
    end
    
    # Track generation
    cycle.track_generation do
      # AI generation happens here
    end
    
    cycle.complete!(
      prompt_tokens: 150,
      completion_tokens: 450,
      total_tokens: 600,
      cost: 0.012
    )
    
    doc_example_output(cycle)
  end
  # endregion cycle-tracking
  
  # region prompt-context-definition
  test "prompt context encompasses more than conversations" do
    context = SolidAgent::Models::PromptContext.create!(
      agent: SolidAgent::Models::Agent.register(TestAgent),
      context_type: "tool_execution",  # Not just conversation!
      status: "active"
    )
    
    # Add different message types
    context.add_system_message("You are a helpful assistant")
    context.add_developer_message("Debug mode enabled")
    context.add_user_message("Analyze this code")
    context.add_assistant_message(
      "I'll analyze the code",
      requested_actions: [
        { name: "code_analysis", id: "call_123", arguments: { file: "app.rb" } }
      ]
    )
    context.add_tool_message("Analysis complete", action_id: "call_123")
    
    doc_example_output(context.messages.map { |m| 
      { role: m.role, content: m.content.truncate(50) }
    })
  end
  # endregion prompt-context-definition
  
  # region action-types
  test "tracks all action types" do
    actions = %w[
      tool function mcp_tool graph_retrieval web_search
      web_browse computer_use api_call database_query
    ].map do |type|
      SolidAgent::Models::ActionExecution.create!(
        action_type: type,
        action_name: "example_#{type}",
        status: "executed"
      )
    end
    
    doc_example_output(actions.map { |a| 
      { type: a.action_type, name: a.action_name }
    })
  end
  # endregion action-types
end