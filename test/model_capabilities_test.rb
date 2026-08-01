# frozen_string_literal: true

require "test_helper"

class ModelCapabilitiesTest < ActiveSupport::TestCase
  teardown { ActiveAgent::ModelCapabilities.reset! }

  test "thinking-first Claude models reject sampling params" do
    %w[claude-sonnet-5 claude-opus-5 claude-fable-5 claude-mythos-5 claude-opus-4-7 claude-opus-4-8].each do |model|
      assert_not ActiveAgent::ModelCapabilities.sampling_supported?(model), "expected #{model} to reject sampling"
    end
  end

  test "OpenAI reasoning models reject sampling params" do
    %w[o1 o1-mini o3-mini o4-mini gpt-5.1 gpt-5].each do |model|
      assert_not ActiveAgent::ModelCapabilities.sampling_supported?(model), "expected #{model} to reject sampling"
    end
  end

  test "conventional models keep sampling params" do
    %w[claude-haiku-4-5 claude-sonnet-4-5 gpt-4o-mini gpt-4.1 qwen3:8b llama3.1:8b].each do |model|
      assert ActiveAgent::ModelCapabilities.sampling_supported?(model), "expected #{model} to support sampling"
    end
  end

  test "sanitize! strips only the rejected params and reports them" do
    parameters = { model: "claude-sonnet-5", temperature: 0.7, top_p: 0.9, max_tokens: 512 }

    removed = ActiveAgent::ModelCapabilities.sanitize!(parameters)

    assert_equal [ :temperature, :top_p ], removed.sort_by(&:to_s)
    assert_equal({ model: "claude-sonnet-5", max_tokens: 512 }, parameters)
  end

  test "sanitize! leaves conventional models untouched" do
    parameters = { model: "gpt-4o-mini", temperature: 0.7 }

    assert_empty ActiveAgent::ModelCapabilities.sanitize!(parameters)
    assert_equal 0.7, parameters[:temperature]
  end

  test "custom rules are consulted ahead of the built-ins" do
    ActiveAgent::ModelCapabilities.register(/\Ahouse-model/, unsupported: [ :temperature ])

    assert_equal [ :temperature ], ActiveAgent::ModelCapabilities.unsupported_params("house-model-2")
    parameters = { model: "house-model-2", temperature: 1.0, top_p: 0.5 }
    ActiveAgent::ModelCapabilities.sanitize!(parameters)
    assert_nil parameters[:temperature]
    assert_equal 0.5, parameters[:top_p]
  end

  test "disabling the switch passes parameters through" do
    ActiveAgent::ModelCapabilities.enabled = false
    parameters = { model: "claude-sonnet-5", temperature: 0.7 }

    assert_empty ActiveAgent::ModelCapabilities.sanitize!(parameters)
    assert_equal 0.7, parameters[:temperature]
  end

  test "prepared prompt parameters are sanitized for the configured model" do
    agent_class = Class.new(ApplicationAgent) do
      def self.name = "SanitizeProbeAgent"
      generate_with :mock, model: "claude-sonnet-5", temperature: 0.7, top_p: 0.9, max_tokens: 256

      def ping
        prompt(message: "hello")
      end
    end

    agent = agent_class.new
    agent.params = {}
    agent.process(:ping)
    parameters = agent.send(:prepare_prompt_parameters)

    assert_nil parameters[:temperature]
    assert_nil parameters[:top_p]
    assert_equal 256, parameters[:max_tokens]
    assert_equal "claude-sonnet-5", parameters[:model]
  end

  test "generation still succeeds end-to-end with stripped params" do
    agent_class = Class.new(ApplicationAgent) do
      def self.name = "SanitizeRunProbeAgent"
      generate_with :mock, model: "claude-fable-5", temperature: 0.2

      def ping
        prompt(message: "hello")
      end
    end

    response = agent_class.with({}).ping.generate_now
    assert response.message.content.present?
  end
end
