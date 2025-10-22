# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/active_agent/providers/mock_provider"

# Test agent using MockProvider to avoid VCR dependencies
class PromptInterfaceTestAgent < ActiveAgent::Base
  generate_with :mock

  def ask
    prompt(message: params[:message])
  end

  def think
    prompt(message: "Think about: #{params[:topic]}")
  end

  def greet(name)
    prompt(message: "Hello #{name}")
  end
end

class PromptInterfaceTest < ActiveSupport::TestCase
  # ========================================
  # Agent.prompt(...).generate_now
  # ========================================

  test "Agent.prompt(...).generate_now works with single message" do
    response = PromptInterfaceTestAgent.prompt(message: "hello world").generate_now

    assert_not_nil response
    # Response should be a Prompt response object
    assert_kind_of ActiveAgent::Providers::Common::Responses::Base, response
    assert_not_nil response.message
    assert_not_nil response.message.content
    # MockProvider converts to pig latin
    assert_includes response.message.content.downcase, "ellohay"
  end

  test "Agent.prompt(...).generate_now works with multiple messages" do
    response = PromptInterfaceTestAgent.prompt(
      messages: [
        { role: "user", content: "first message" },
        { role: "user", content: "second message" }
      ]
    ).generate_now

    assert_not_nil response
    assert_kind_of ActiveAgent::Providers::Common::Responses::Base, response
    assert_not_nil response.message
  end

  test "Agent.prompt(...).generate_now works with options" do
    response = PromptInterfaceTestAgent.prompt(
      message: "test",
      temperature: 0.8
    ).generate_now

    assert_not_nil response
    assert_kind_of ActiveAgent::Providers::Common::Responses::Base, response
  end

  # ========================================
  # Agent.with(...).action.generate_now
  # ========================================

  test "Agent.with(...).ask.generate_now works" do
    response = PromptInterfaceTestAgent.with(message: "hello world").ask.generate_now

    assert_not_nil response
    assert_kind_of ActiveAgent::Providers::Common::Responses::Base, response
    assert_not_nil response.message
    # MockProvider converts to pig latin
    assert_includes response.message.content.downcase, "ellohay"
  end

  test "Agent.with(...).think.generate_now works" do
    response = PromptInterfaceTestAgent.with(topic: "philosophy").think.generate_now

    assert_not_nil response
    assert_kind_of ActiveAgent::Providers::Common::Responses::Base, response
    assert_not_nil response.message
    # Should contain "philosophy" in pig latin form
    assert_not_nil response.message.content
  end

  test "Agent.with(...).action.generate_now works with multiple params" do
    response = PromptInterfaceTestAgent.with(
      message: "complex query",
      temperature: 0.5
    ).ask.generate_now

    assert_not_nil response
    assert_kind_of ActiveAgent::Providers::Common::Responses::Base, response
  end

  # ========================================
  # Agent.action(*args).generate_now
  # ========================================

  test "Agent.action(args).generate_now works" do
    response = PromptInterfaceTestAgent.greet("Alice").generate_now

    assert_not_nil response
    assert_kind_of ActiveAgent::Providers::Common::Responses::Base, response
    assert_not_nil response.message
    # MockProvider should process "Hello Alice"
    assert_not_nil response.message.content
  end

  test "calling action without parameterization returns Generation" do
    generation = PromptInterfaceTestAgent.greet("Bob")

    assert_instance_of ActiveAgent::Generation, generation
    assert_not generation.processed?
  end

  # ========================================
  # Agent.prompt(...).generate_later
  # ========================================

  test "Agent.prompt(...).generate_later enqueues job" do
    generation = PromptInterfaceTestAgent.prompt(message: "test")

    # Mock the enqueue_generation method to verify it's called
    generation.instance_eval do
      def enqueue_generation(method, options)
        @enqueued_method = method
        @enqueued_options = options
        self
      end
    end

    generation.generate_later(queue: :prompts)

    assert_equal :generate_now, generation.instance_variable_get(:@enqueued_method)
    assert_equal({ queue: :prompts }, generation.instance_variable_get(:@enqueued_options))
  end

  # ========================================
  # Agent.with(...).action.generate_later
  # ========================================

  test "Agent.with(...).ask.generate_later enqueues job" do
    generation = PromptInterfaceTestAgent.with(message: "test").ask

    # Mock the enqueue_generation method
    generation.instance_eval do
      def enqueue_generation(method, options)
        @enqueued_method = method
        @enqueued_options = options
        self
      end
    end

    generation.generate_later(queue: :agents, priority: :high)

    assert_equal :generate_now, generation.instance_variable_get(:@enqueued_method)
    assert_equal({ queue: :agents, priority: :high }, generation.instance_variable_get(:@enqueued_options))
  end

  test "Agent.with(...).think.generate_later enqueues job" do
    generation = PromptInterfaceTestAgent.with(topic: "nature").think

    # Mock the enqueue_generation method
    generation.instance_eval do
      def enqueue_generation(method, options)
        @enqueued_method = method
        self
      end
    end

    generation.generate_later

    assert_equal :generate_now, generation.instance_variable_get(:@enqueued_method)
  end

  # ========================================
  # Agent.action(*args).generate_later
  # ========================================

  test "Agent.action(args).generate_later enqueues job" do
    generation = PromptInterfaceTestAgent.greet("Charlie")

    # Mock the enqueue_generation method
    generation.instance_eval do
      def enqueue_generation(method, options)
        @enqueued_method = method
        @enqueued_options = options
        self
      end
    end

    generation.generate_later(wait: 10.minutes)

    assert_equal :generate_now, generation.instance_variable_get(:@enqueued_method)
    assert_equal({ wait: 10.minutes }, generation.instance_variable_get(:@enqueued_options))
  end

  # ========================================
  # Mixed patterns and edge cases
  # ========================================

  test "Generation proxy provides access to prompt properties before execution" do
    generation = PromptInterfaceTestAgent.prompt(message: "inspect me")

    # Should be able to access prompt properties without executing
    assert_not generation.processed?
    assert_not_nil generation.message
    assert_equal "inspect me", generation.message.content
    assert_not_nil generation.messages
    assert generation.messages.size > 0
  end

  test "Parameterized generation provides access to prompt properties" do
    generation = PromptInterfaceTestAgent.with(message: "test message").ask

    # Should be able to access prompt properties
    assert_not generation.processed?
    assert_not_nil generation.message
    assert_not_nil generation.messages
  end

  test "All generation methods return proper Response type" do
    # Test that all interfaces return the same response type
    responses = [
      PromptInterfaceTestAgent.prompt(message: "test").generate_now,
      PromptInterfaceTestAgent.with(message: "test").ask.generate_now,
      PromptInterfaceTestAgent.greet("test").generate_now
    ]

    responses.each do |response|
      assert_kind_of ActiveAgent::Providers::Common::Responses::Base, response
      assert_not_nil response.message
      assert_not_nil response.messages
    end
  end

  test "generate_now! also works for all patterns" do
    # Test the bang version which processes immediately
    responses = [
      PromptInterfaceTestAgent.prompt(message: "test").generate_now!,
      PromptInterfaceTestAgent.with(message: "test").ask.generate_now!,
      PromptInterfaceTestAgent.greet("test").generate_now!
    ]

    responses.each do |response|
      assert_kind_of ActiveAgent::Providers::Common::Responses::Base, response
      assert_not_nil response.message
    end
  end

  test "generate_later! also works for all patterns" do
    generations = [
      PromptInterfaceTestAgent.prompt(message: "test"),
      PromptInterfaceTestAgent.with(message: "test").ask,
      PromptInterfaceTestAgent.greet("test")
    ]

    generations.each do |generation|
      # Mock enqueue_generation for each
      generation.instance_eval do
        def enqueue_generation(method, options)
          @enqueued_bang_method = method
          self
        end
      end

      generation.generate_later!

      assert_equal :generate_now!, generation.instance_variable_get(:@enqueued_bang_method)
    end
  end
end
