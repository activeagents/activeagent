# frozen_string_literal: true

require "test_helper"

# An agent that renders its user turn from the action's template — the
# idiomatic `instructions:` + `locals:` form — passes no `messages:`, so the
# instrumentation had nothing to record and `prompt.input.messages` was absent
# from its traces. The system prompt and the completion were both captured,
# which made the gap easy to miss: a trace looked populated while the half an
# evaluation scores, what the user actually said, was missing.
class RenderedMessagesTest < ActiveSupport::TestCase
  class Recorder
    attr_reader :attributes

    def initialize = @attributes = {}
    def set_attribute(key, value) = @attributes[key] = value
  end

  # Stands in for an agent whose messages only exist once the templates run.
  class TemplateRenderingAgent
    include ActiveAgent::Telemetry::Instrumentation::GenerationInstrumentation

    def initialize(rendered:, explicit: nil, raises: false)
      @rendered = rendered
      @explicit = explicit
      @raises = raises
    end

    def prompt_options = { messages: @explicit }.compact

    def prepare_prompt_parameters
      raise "templates unavailable" if @raises

      { messages: @rendered }
    end

    def logger = nil
  end

  def messages_for(agent)
    agent.send(:rendered_prompt_messages)
  end

  test "reads the messages the templates rendered" do
    agent = TemplateRenderingAgent.new(rendered: [ { role: "user", content: "rendered turn" } ])

    assert_equal [ { role: "user", content: "rendered turn" } ], messages_for(agent)
  end

  test "a failure to render costs the generation nothing but the attribute" do
    agent = TemplateRenderingAgent.new(rendered: nil, raises: true)

    assert_nil messages_for(agent)
  end

  test "an agent without prepare_prompt_parameters is left alone" do
    bare = Class.new do
      include ActiveAgent::Telemetry::Instrumentation::GenerationInstrumentation
      def logger = nil
    end.new

    assert_nil bare.send(:rendered_prompt_messages)
  end
end
