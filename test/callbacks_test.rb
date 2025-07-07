# frozen_string_literal: true

require "abstract_unit"
require "agents/callback_agent"
require "active_support/testing/stream"

class ActiveAgentCallbacksTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::Stream

  setup do
    @previous_generation_provider = ActiveAgent::Base.generation_provider
    ActiveAgent::Base.generation_provider = :test
    CallbackAgent.rescue_from_error = nil
    CallbackAgent.after_generation_instance = nil
    CallbackAgent.around_generation_instance = nil
    CallbackAgent.abort_before_generation = nil
    CallbackAgent.around_handles_error = nil
  end

  teardown do
    ActiveAgent::Base.generations.clear
    ActiveAgent::Base.generation_provider = @previous_generation_provider
    CallbackAgent.rescue_from_error = nil
    CallbackAgent.after_generation_instance = nil
    CallbackAgent.around_generation_instance = nil
    CallbackAgent.abort_before_generation = nil
    CallbackAgent.around_handles_error = nil
  end

  test "generate_now should call after_generation callback and can access prompt message" do
    prompt_generation = CallbackAgent.test_message
    prompt_generation.generate_now
    assert_kind_of CallbackAgent, CallbackAgent.after_generation_instance
    assert_not_empty CallbackAgent.after_generation_instance.message.message_id
    assert_equal prompt_generation.message_id, CallbackAgent.after_generation_instance.message.message_id
    assert_equal "test-receiver@test.com", CallbackAgent.after_generation_instance.message.to.first
  end

  test "generate_now should call after_generation callback" do
    CallbackAgent.test_message.generate_now

    assert_kind_of CallbackAgent, CallbackAgent.after_generation_instance
  end

  test "before_generation can abort the generation and not run after_generation callbacks" do
    CallbackAgent.abort_before_generation = true

    prompt_generation = CallbackAgent.test_message
    prompt_generation.generate_now

    assert_equal prompt_generation.message.content, "Test Body"
    assert_nil CallbackAgent.after_generation_instance
  end

  test "generate_later should call after_generation callback and can access sent message" do
    perform_enqueued_jobs do
      silence_stream($stdout) do
        CallbackAgent.test_message.generate_later
      end
    end
    assert_kind_of CallbackAgent, CallbackAgent.after_generation_instance
    assert_not_empty CallbackAgent.after_generation_instance.message.message_id
  end

  test "around_generation is called after rescue_from on action processing exceptions" do
    CallbackAgent.around_handles_error = true

    CallbackAgent.test_raise_action.generate_now
    assert CallbackAgent.rescue_from_error
  end

  test "around_generation is called before rescue_from on generation! exceptions" do
    CallbackAgent.around_handles_error = true

    stub_any_instance(ActiveAgent::GenerationProvider::TestProvider, instance: ActiveAgent::GenerationProvider::TestProvider.new({})) do |instance|
      instance.stub(:generate!, proc { raise "boom generation exception" }) do
        CallbackAgent.test_message.generate_now
      end
    end

    assert_kind_of CallbackAgent, CallbackAgent.after_generation_instance
    assert_nil CallbackAgent.rescue_from_error
  end
end
