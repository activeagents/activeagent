require "test_helper"
require "solid_agent"

class SolidAgent::PersistableTest < ActiveSupport::TestCase
  class TestAgent < ActiveAgent::Base
    include SolidAgent::Persistable
    
    def analyze
      prompt
    end
    
    def search(query:)
      # Tool action
    end
  end
  
  class NonPersistableAgent < ActiveAgent::Base
    self.solid_agent_enabled = false
    
    def process
      prompt
    end
  end
  
  setup do
    @agent = TestAgent.new
    SolidAgent.configuration.auto_persist = true
  end
  
  teardown do
    # Clean up test data
    SolidAgent::Models::PromptContext.destroy_all
    SolidAgent::Models::Agent.destroy_all
  end
  
  test "automatically registers agent on first use" do
    assert_difference "SolidAgent::Models::Agent.count", 1 do
      @agent.analyze
    end
    
    agent_record = SolidAgent::Models::Agent.last
    assert_equal "SolidAgent::PersistableTest::TestAgent", agent_record.class_name
    assert_equal "active", agent_record.status
  end
  
  test "persists prompt context automatically" do
    assert_difference "SolidAgent::Models::PromptContext.count", 1 do
      @agent.analyze
    end
    
    context = SolidAgent::Models::PromptContext.last
    assert_equal "runtime", context.context_type
    assert_equal "active", context.status
  end
  
  test "persists all messages in prompt" do
    @agent.instance_variable_set(:@context, 
      OpenStruct.new(prompt: OpenStruct.new(
        messages: [
          ActiveAgent::ActionPrompt::Message.new(role: :system, content: "You are a helpful assistant"),
          ActiveAgent::ActionPrompt::Message.new(role: :user, content: "Hello world")
        ]
      ))
    )
    
    assert_difference "SolidAgent::Models::Message.count", 2 do
      @agent.analyze
    end
    
    messages = SolidAgent::Models::Message.order(:position)
    assert_equal "system", messages.first.role
    assert_equal "You are a helpful assistant", messages.first.content
    assert_equal "user", messages.second.role
    assert_equal "Hello world", messages.second.content
  end
  
  test "tracks generation automatically" do
    @agent.instance_variable_set(:@generation_provider, "openai")
    
    assert_difference "SolidAgent::Models::Generation.count", 1 do
      VCR.use_cassette("solid_agent_generation") do
        @agent.generate(prompt: "Test prompt")
      end
    end
    
    generation = SolidAgent::Models::Generation.last
    assert_equal "openai", generation.provider
    assert_equal "processing", generation.status
  end
  
  test "respects solid_agent_enabled flag" do
    agent = NonPersistableAgent.new
    
    assert_no_difference "SolidAgent::Models::PromptContext.count" do
      agent.process
    end
  end
  
  test "tracks action executions" do
    assert_difference "SolidAgent::Models::ActionExecution.count", 1 do
      @agent.search(query: "ruby gems")
    end
    
    action = SolidAgent::Models::ActionExecution.last
    assert_equal "search", action.action_name
    assert_equal "function", action.action_type
    assert_equal({ "query" => "ruby gems" }, action.parameters)
  end
  
  test "handles multimodal content" do
    @agent.instance_variable_set(:@context,
      OpenStruct.new(prompt: OpenStruct.new(
        messages: [
          ActiveAgent::ActionPrompt::Message.new(
            role: :user,
            content: [
              { type: "text", text: "What's in this image?" },
              { type: "image", image: "base64_encoded_image" }
            ]
          )
        ]
      ))
    )
    
    @agent.analyze
    
    message = SolidAgent::Models::Message.last
    assert_equal "multimodal", message.content_type
    assert message.multimodal?
  end
  
  test "calculates cost automatically" do
    generation = SolidAgent::Models::Generation.create!(
      prompt_context: SolidAgent::Models::PromptContext.create!(
        agent: SolidAgent::Models::Agent.register(TestAgent)
      ),
      provider: "openai",
      model: "gpt-4",
      prompt_tokens: 100,
      completion_tokens: 200,
      total_tokens: 300
    )
    
    generation.send(:calculate_cost)
    
    # GPT-4 pricing: $0.03/1k prompt, $0.06/1k completion
    expected_cost = (100 * 0.03 / 1000) + (200 * 0.06 / 1000)
    assert_in_delta expected_cost, generation.cost, 0.0001
  end
  
  test "updates usage metrics" do
    agent = SolidAgent::Models::Agent.register(TestAgent)
    date = Date.current
    
    generation = SolidAgent::Models::Generation.create!(
      prompt_context: SolidAgent::Models::PromptContext.create!(agent: agent),
      provider: "openai",
      model: "gpt-4",
      total_tokens: 500,
      cost: 0.025
    )
    
    @agent.send(:update_usage_metrics, {
      total_tokens: 500
    })
    
    metric = SolidAgent::Models::UsageMetric.find_by(
      agent: agent,
      date: date,
      provider: "openai",
      model: "gpt-4"
    )
    
    assert_equal 1, metric.total_requests
    assert_equal 500, metric.total_tokens
  end
  
  test "persists assistant responses and tool calls" do
    response = OpenStruct.new(
      message: OpenStruct.new(content: "I'll help you with that."),
      requested_actions: [
        { name: "search", id: "call_123", arguments: { query: "test" } }
      ]
    )
    
    @agent.instance_variable_set(:@_solid_prompt_context,
      SolidAgent::Models::PromptContext.create!(
        agent: SolidAgent::Models::Agent.register(TestAgent)
      )
    )
    
    @agent.send(:persist_assistant_response, response)
    
    message = SolidAgent::Models::Message.last
    assert_equal "assistant", message.role
    assert_equal "I'll help you with that.", message.content
    
    action = message.actions.first
    assert_equal "search", action.action_name
    assert_equal "call_123", action.action_id
    assert_equal({ "query" => "test" }, action.parameters)
  end
end