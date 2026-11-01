# frozen_string_literal: true

require "test_helper"
require "mcp"
require_relative "../../lib/active_agent/providers/anthropic_provider"
require_relative "../../lib/active_agent/providers/open_ai/chat_provider"

# Capture over the tool loops of real providers: a tool served by a
# client-side MCP server is recorded once, streamed or not, and a call that
# pauses for approval never reaches the server and is not recorded as run.
# The wire is stubbed and the MCP server is a stand-in client.
class EvalsCaptureMCPProvidersTest < ActiveSupport::TestCase
  include WebMock::API

  Capture = ActiveAgent::Evals::Capture

  OPENAI_ENDPOINT = "https://api.openai.com/v1/chat/completions"
  ANTHROPIC_ENDPOINT = %r{\Ahttps://api\.anthropic\.com/v1/messages}
  SERVER = { name: "pages", url: "https://mcp.example.test/mcp" }.freeze
  ORDER_TOOL = {
    name: "lookup_order", description: "Look up an order",
    parameters: { type: "object", properties: { number: { type: "string" } }, required: [ "number" ] }
  }.freeze

  class FakeClient
    attr_reader :calls

    def initialize(answer = { "content" => [ { "type" => "text", "text" => "<html>Example</html>" } ] })
      @answer = answer
      @calls = []
    end

    def tools
      [ MCP::Client::Tool.new(name: "get_page", description: "Fetch a page", input_schema: { type: "object", properties: { url: { type: "string" } } }) ]
    end

    def call_tool(name:, arguments:)
      @calls << [ name, arguments ]
      { "jsonrpc" => "2.0", "id" => 1, "result" => @answer }
    end
  end

  class ChatAgent < ApplicationAgent
    generate_with :openai, model: "gpt-4o-mini", api_key: "test-key", api_version: :chat

    class_attribute :orders, default: []

    def research(stream: false)
      prompt(message: "Check order 7 and fetch the page", tools: [ ORDER_TOOL ], mcps: [ SERVER ], mcp_strategy: :client, stream:)
    end

    def lookup_order(number:)
      orders << number
      { status: "shipped" }
    end
  end

  class MessagesAgent < ApplicationAgent
    generate_with :anthropic, model: "claude-sonnet-4-5", api_key: "test-key"

    def fetch(server: SERVER, strategy: :auto)
      prompt(message: "Fetch the page", mcps: [ server ], mcp_strategy: strategy)
    end
  end

  setup do
    ActiveAgent::Providers::MCPToolCache.reset!
    ChatAgent.orders = []
  end

  teardown { ActiveAgent::Providers::MCPToolCache.reset! }

  def chat_completion(tool_calls: nil, content: nil)
    {
      id: "chatcmpl-#{SecureRandom.hex(4)}", object: "chat.completion", created: 1_761_502_994, model: "gpt-4o-mini",
      choices: [ { index: 0, message: { role: "assistant", content:, tool_calls: }.compact, finish_reason: tool_calls ? "tool_calls" : "stop" } ],
      usage: { prompt_tokens: 20, completion_tokens: 10, total_tokens: 30 }
    }
  end

  # The chunks of a real Chat Completions stream for the same completion.
  def chat_sse(body)
    message = body[:choices].first[:message]
    deltas = [ { role: "assistant", content: message[:content] ? "" : nil }.compact ]

    deltas << { content: message[:content] } if message[:content]
    Array(message[:tool_calls]).each_with_index do |call, index|
      deltas << { tool_calls: [ { index:, id: call[:id], type: "function", function: { name: call.dig(:function, :name), arguments: "" } } ] }
      deltas << { tool_calls: [ { index:, function: { arguments: call.dig(:function, :arguments) } } ] }
    end

    chunks = deltas.map { { choices: [ { index: 0, delta: _1, finish_reason: nil } ] } }
    chunks << { choices: [ { index: 0, delta: {}, finish_reason: body[:choices].first[:finish_reason] } ] }
    chunks << { choices: [], usage: body[:usage] }

    envelope = { id: body[:id], object: "chat.completion.chunk", created: body[:created], model: body[:model] }
    chunks.map { "data: #{envelope.merge(_1).to_json}\n\n" }.join + "data: [DONE]\n\n"
  end

  def stub_chat(*bodies, stream:)
    @request_bodies = []
    responses = bodies.map do |body|
      if stream
        { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: chat_sse(body) }
      else
        { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
      end
    end

    stub_request(:post, OPENAI_ENDPOINT).with { |request| @request_bodies << JSON.parse(request.body) }.to_return(*responses)
  end

  def stub_messages(*messages)
    @request_bodies = []
    stub_request(:post, ANTHROPIC_ENDPOINT)
      .with { |request| @request_bodies << JSON.parse(request.body) }
      .to_return(*messages.map { { status: 200, headers: { "Content-Type" => "application/json" }, body: _1.to_json } })
  end

  def assistant_message(*content)
    stop_reason = content.any? { |block| block[:type] == "tool_use" } ? "tool_use" : "end_turn"

    { id: "msg_#{SecureRandom.hex(4)}", type: "message", role: "assistant", model: "claude-sonnet-4-5",
      content:, stop_reason:, stop_sequence: nil, usage: { input_tokens: 20, output_tokens: 10 } }
  end

  def function_call(id, name, arguments)
    { id:, type: "function", function: { name:, arguments: arguments.to_json } }
  end

  def get_page = { type: "tool_use", id: "toolu_1", name: "get_page", input: { url: "https://example.test" } }

  # Builds every bridge over +client+, so no transport is opened.
  def with_fake_server(client, &test)
    build = lambda do |servers, cache: nil|
      bridge = ActiveAgent::Providers::MCPBridge.allocate
      bridge.send(:initialize, servers, cache:)
      bridge.define_singleton_method(:connect) do |declaration|
        server = ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client:)
        @servers << server
        server
      end
      bridge
    end

    ActiveAgent::Providers::MCPBridge.stub(:new, build, &test)
  end

  [ false, true ].each do |stream|
    test "a local and an MCP tool in one #{stream ? 'streamed' : 'plain'} tool loop are each recorded once" do
      client = FakeClient.new
      stub_chat(
        chat_completion(tool_calls: [ function_call("call_1", "lookup_order", number: "7"), function_call("call_2", "get_page", url: "https://example.test") ]),
        chat_completion(content: "Done."),
        stream:
      )

      replay = with_fake_server(client) { Capture.run(ChatAgent.research(stream:)) }

      assert_equal "Done.", replay.answer
      assert_equal %w[lookup_order get_page], replay.tool_names
      assert_equal({ "number" => "7" }, replay.tool_calls.first["arguments"])
      assert_equal({ "url" => "https://example.test" }, replay.tool_calls.last["arguments"])
      assert_includes replay.tool_calls.last["detail"], "<html>Example</html>"
      assert_empty replay.failed_tool_calls
      assert_equal [ "7" ], ChatAgent.orders
      assert_equal [ [ "get_page", { url: "https://example.test" } ] ], client.calls
      tool_messages = @request_bodies.last["messages"].select { _1["role"] == "tool" }
      assert_equal [ "call_1", "call_2" ], tool_messages.pluck("tool_call_id")
      assert_equal "<html>Example</html>".to_json, tool_messages.last["content"]
    end
  end

  test "a result the MCP server marked as an error is recorded as failed and reaches the model as one" do
    client = FakeClient.new({ "isError" => true, "content" => [ { "type" => "text", "text" => "Invalid params" } ] })
    stub_messages(assistant_message(get_page), assistant_message({ type: "text", text: "Sorry." }))

    replay = with_fake_server(client) { Capture.run(MessagesAgent.fetch(strategy: :client), raise_errors: true) }

    assert_equal "Sorry.", replay.answer
    assert_equal [ "get_page" ], replay.failed_tool_calls.pluck("name")
    assert_equal "Invalid params", replay.failed_tool_calls.first["detail"]
    result = @request_bodies.last["messages"].last["content"].first
    assert_equal true, result["is_error"]
    assert_equal({ error: "Invalid params" }.to_json, result["content"])
    assert_equal 1, client.calls.length
  end

  test "a call that needs approval pauses before the server and is not recorded as run" do
    client = FakeClient.new
    stub_messages(assistant_message(get_page))

    replay = with_fake_server(client) { Capture.run(MessagesAgent.fetch(server: SERVER.merge(require_approval: "always")), raise_errors: true) }

    refute replay.errored?
    assert_empty replay.tool_calls
    assert_empty client.calls
  end

  test "an MCP server served by the provider itself is not recorded, and nothing is claimed about it" do
    stub_messages(assistant_message({ type: "text", text: "Done." }))

    replay = Capture.run(MessagesAgent.fetch, raise_errors: true)

    assert_empty replay.tool_calls
    assert_equal [ "pages" ], @request_bodies.first["mcp_servers"].pluck("name")
  end
end
