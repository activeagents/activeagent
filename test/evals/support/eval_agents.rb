# frozen_string_literal: true

# An offline agent with a tool for the Capture and TestHelper tests: the
# mock provider never calls tools, so this one does, deterministically, from
# the prompt — "order ABC-123" looks the order up, anything else is refused.
require "active_agent/providers/mock_provider"

module EvalsTest
  class ToolCallingMockProvider < ActiveAgent::Providers::MockProvider
    # A provider resolves its service, tag and option types from its class
    # name; this one borrows the mock's.
    def self.service_name = "Mock"
    def self.tag_name = "Mock"
    def self.namespace = ActiveAgent::Providers::Mock

    protected

    def api_prompt_execute(parameters)
      text = extract_message_content(parameters[:messages]&.last&.dig(:content))
      answer =
        if (number = text[/order ([A-Z]+-\d+)/i, 1])
          result = call_tool_function("lookup_order", number: number)
          "Order #{number} is #{result[:status]}."
        else
          "I don't have access to that."
        end

      {
        "id" => "mock-#{SecureRandom.hex(4)}",
        "type" => "message",
        "role" => "assistant",
        "content" => [ { "type" => "text", "text" => answer } ],
        "model" => parameters[:model] || "mock-model",
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 12, "output_tokens" => 7 }
      }
    end
  end

  class OrdersAgent < ActiveAgent::Base
    generate_with :mock, model: "mock-orders"
    self._prompt_provider_klass = ToolCallingMockProvider

    # Renders help.text.erb: "Where is order <number>?"
    def help
      prompt
    end

    def ask
      prompt(message: params[:question], instructions: "You answer order questions.")
    end

    def lookup_order(number:)
      raise ArgumentError, "no such order #{number}" if number.start_with?("BAD")

      { status: "shipped", number: number }
    end
  end
end
