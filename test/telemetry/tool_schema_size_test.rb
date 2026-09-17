# frozen_string_literal: true

require "test_helper"

# The tool roster on a prompt span is a reading aid — names, a clipped
# description, parameter keys — while the model is sent the whole JSON Schema.
# A context meter sizing tool pressure from the roster would understate it, so
# the schemas' own size travels as `prompt.input.tools.tokens`.
class ToolSchemaSizeTest < ActiveSupport::TestCase
  class Agent
    prepend ActiveAgent::Telemetry::Instrumentation::GenerationInstrumentation

    attr_reader :prompt_options

    def initialize(tools)
      @prompt_options = { tools: tools }
    end

    def action_name = "ask"
    def process_prompt = :generated
  end

  def setup
    @config = ActiveAgent::Telemetry.configuration
    @saved = { enabled: @config.enabled, api_key: @config.api_key, local_storage: @config.local_storage }
    @config.enabled = true
    @config.api_key = "test-key"
    @config.local_storage = true
  end

  def teardown
    @config.enabled = @saved[:enabled]
    @config.api_key = @saved[:api_key]
    @config.local_storage = @saved[:local_storage]
    ActiveAgent::Telemetry.tracer.clear if ActiveAgent::Telemetry.tracer.respond_to?(:clear)
  end

  # A schema whose description and nested properties are far larger than the
  # roster that summarizes it.
  def schema(name)
    {
      name: name,
      description: "d" * 2000,
      parameters: {
        type: "object",
        properties: { query: { type: "string", description: "q" * 2000 } }
      }
    }
  end

  def prompt_attributes(tools)
    captured = nil
    ActiveAgent::Telemetry.stub(:trace, ->(_name, **_opts, &block) {
      span = FakeSpan.new
      block.call(span)
      captured = span.children.first&.attributes || {}
      :generated
    }) do
      Agent.new(tools).process_prompt
    end
    captured
  end

  class FakeSpan
    attr_reader :attributes, :children

    def initialize
      @attributes = {}
      @children = []
    end

    def add_span(_name, span_type: nil)
      FakeSpan.new.tap { |span| children << span }
    end

    def set_attribute(key, value) = attributes[key] = value
    def set_status(*) = nil
    def record_error(*) = nil
    def finish = nil
  end

  test "the recorded size measures the schemas, not the roster that summarizes them" do
    tools = [ schema("search") ]

    attributes = prompt_attributes(tools)

    roster_tokens = attributes["prompt.input.tools"].length / 4.0
    assert_equal (tools.to_json.length / 4.0).round, attributes["prompt.input.tools.tokens"]
    assert_operator attributes["prompt.input.tools.tokens"], :>, roster_tokens * 2,
      "the schemas are several times the roster, so sizing the roster understates them"
  end

  # Schemas come from the host and need not be serializable. A size is worth
  # less than the generation it would otherwise take down.
  test "a schema that cannot be serialized costs the size but not the generation" do
    cyclic = schema("search")
    cyclic[:parameters][:properties][:query][:self] = cyclic

    attributes = prompt_attributes([ cyclic ])

    assert attributes["prompt.input.tools"].present?, "the roster is still recorded"
    assert_nil attributes["prompt.input.tools.tokens"]
  end

  test "no tools means no tool attributes" do
    assert_nil prompt_attributes([])["prompt.input.tools"]
  end
end
