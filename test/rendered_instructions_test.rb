# frozen_string_literal: true

require "test_helper"

# Rendering an agent's instructions without running it: what a dashboard that
# mirrors the class needs (ActionAgent::AgentSync), and what a test asserting
# what the model is told needs. Both otherwise reach a private renderer
# through `send`.
class RenderedInstructionsProbeAgent < ActiveAgent::Base
end

class RenderedInstructionsTest < ActiveSupport::TestCase
  test "renders the agent's own instructions template" do
    assert_equal "You are the probe agent.", RenderedInstructionsProbeAgent.rendered_instructions
  end

  test "assigns reach the template" do
    # The hub case: instructions describing a roster the class computes.
    assert_equal(
      "You are the probe agent for tickets.",
      RenderedInstructionsProbeAgent.rendered_instructions(topic: "tickets")
    )
  end

  test "returns nil when the agent has no instructions template" do
    agent = Class.new(ActiveAgent::Base) do
      def self.name = "NoInstructionsTemplateAgent"
    end

    assert_nil agent.rendered_instructions
  end
end
