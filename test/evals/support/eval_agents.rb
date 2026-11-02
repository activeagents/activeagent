# frozen_string_literal: true

# An offline agent with a tool for the Capture and TestHelper tests: the
# mock provider never calls tools, so this one does, deterministically, from
# the prompt — "order ABC-123" looks the order up, anything else is refused.
require "mcp"
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

  # Answers a bridged server's tool calls from a list, one answer per call
  # (the last repeats): a tool result, or an exception to raise, as the real
  # client raises on a transport failure. It keeps what it was called with.
  class FakeMCPClient
    HTML = { "content" => [ { "type" => "text", "text" => "<html>Example</html>" } ] }.freeze
    INVALID = { "isError" => true, "content" => [ { "type" => "text", "text" => "Invalid params" } ] }.freeze

    attr_reader :calls

    def initialize(*answers)
      @answers = answers.presence || [ HTML ]
      @calls = []
    end

    def tools
      [ MCP::Client::Tool.new(name: "get_page", description: "Fetch a page", input_schema: nil) ]
    end

    def call_tool(name:, arguments:)
      @calls << [ name, arguments ]
      answer = @answers[[ @calls.length - 1, @answers.length - 1 ].min]
      raise answer if answer.is_a?(Exception)

      { "jsonrpc" => "2.0", "id" => @calls.length, "result" => answer }
    end
  end

  # Calls the agent's own lookup_order for each "order X" in the prompt and an
  # MCP-served get_page for each "fetch URL", in the order they appear, and
  # answers with what each one gave back. A page that failed on the server
  # arrives as the bridge's ErrorResult, which this reports in the answer.
  class MCPCallingMockProvider < ToolCallingMockProvider
    protected

    def api_prompt_execute(parameters)
      text = extract_message_content(parameters[:messages]&.last&.dig(:content))
      outcomes = text.scan(/\b(order|fetch) (\S+)/i).map do |kind, target|
        if kind.casecmp?("order")
          "order #{target} #{call_tool_function('lookup_order', number: target)[:status]}"
        else
          page = call_tool_function("get_page", url: target)
          page.is_a?(ActiveAgent::Providers::MCPBridge::ErrorResult) ? "page failed: #{page.message}" : "page #{page}"
        end
      end

      {
        "id" => "mock-#{SecureRandom.hex(4)}",
        "type" => "message",
        "role" => "assistant",
        "content" => [ { "type" => "text", "text" => outcomes.join("; ") } ],
        "model" => parameters[:model] || "mock-model",
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 12, "output_tokens" => 7 }
      }
    end
  end

  class MCPAgent < ActiveAgent::Base
    generate_with :mock, model: "mock-mcp", mcp_strategy: :client,
                         mcps: [ { name: "pages", url: "https://mcp.example.test/mcp" } ]
    self._prompt_provider_klass = MCPCallingMockProvider

    def ask
      prompt(message: params[:question])
    end

    def lookup_order(number:)
      { status: "shipped", number: number }
    end
  end
end
