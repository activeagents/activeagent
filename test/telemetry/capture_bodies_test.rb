# frozen_string_literal: true

require "test_helper"

# Message bodies — prompt, completion, tool arguments and results — go on a
# span only when capture_bodies is on (#394). Off by default when traces
# leave the process; on by default under local_storage, where they don't.
class CaptureBodiesTest < ActiveSupport::TestCase
  class Span
    attr_reader :attributes, :children

    def initialize
      @attributes = {}
      @children = []
    end

    def add_span(_name, span_type: nil)
      Span.new.tap { |span| children << span }
    end

    def set_attribute(key, value) = attributes[key] = value
    def set_status(*) = nil
    def record_error(*) = nil
    def finish = nil
  end

  # What ActiveAgent::Base provides underneath the prepended instrumentation.
  class Base
    def tools_function
      proc { |name, *_args, **_kwargs| "result for #{name}" }
    end
  end

  class ToolAgent < Base
    prepend ActiveAgent::Telemetry::Instrumentation::GenerationInstrumentation
  end

  def setup
    @config = ActiveAgent::Telemetry.configuration
    @saved = { enabled: @config.enabled, api_key: @config.api_key, capture_bodies: @config.capture_bodies }
    @config.enabled = true
    @config.api_key = "test-key"
  end

  def teardown
    @config.enabled = @saved[:enabled]
    @config.api_key = @saved[:api_key]
    @config.capture_bodies = @saved[:capture_bodies]
  end

  def tool_span_attributes
    agent = ToolAgent.new
    parent = Span.new
    agent.instance_variable_set(:@_telemetry_llm_span, parent)

    result = agent.tools_function.call("search", q: "order 88213")
    assert_equal "result for search", result, "the wrapped tool must still run"

    parent.children.first.attributes
  end

  test "tool arguments and results stay off the span when capture_bodies is off" do
    @config.capture_bodies = false

    attributes = tool_span_attributes

    assert_equal "search", attributes["tool.name"], "the tool's name is always recorded"
    assert_nil attributes["tool.input.args"]
    assert_nil attributes["tool.output.result"]
  end

  test "tool arguments and results are recorded when capture_bodies is on" do
    @config.capture_bodies = true

    attributes = tool_span_attributes

    assert_equal({ "q" => "order 88213" }.to_json, attributes["tool.input.args"])
    assert_equal "result for search", attributes["tool.output.result"]
  end

  test "capture_bodies is off by default" do
    assert_not ActiveAgent::Telemetry::Configuration.new.capture_bodies?
  end

  test "local storage turns capture_bodies on unless the app said otherwise" do
    config = ActiveAgent::Telemetry::Configuration.new
    config.local_storage = true

    assert config.capture_bodies?
  end

  test "an explicit capture_bodies wins over the local storage default in either order" do
    first = ActiveAgent::Telemetry::Configuration.new
    first.capture_bodies = false
    first.local_storage = true
    assert_not first.capture_bodies?

    second = ActiveAgent::Telemetry::Configuration.new
    second.local_storage = true
    second.capture_bodies = false
    assert_not second.capture_bodies?
  end

  test "the YAML loader honours an explicit capture_bodies beside local_storage" do
    config = ActiveAgent::Telemetry::Configuration.new
    config.load_from_hash("local_storage" => true, "capture_bodies" => false)

    assert config.local_storage?
    assert_not config.capture_bodies?
  end
end
