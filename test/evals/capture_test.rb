# frozen_string_literal: true

require "test_helper"
require_relative "support/eval_agents"

class EvalsCaptureTest < ActiveSupport::TestCase
  Capture = ActiveAgent::Evals::Capture
  Replay = ActiveAgent::Evals::Replay

  test "a generation becomes a replay with the answer, tokens, timing and the prompt" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(question: "Where is order ABC-123?").ask)

    assert_kind_of Replay, replay
    assert_equal "Order ABC-123 is shipped.", replay.answer
    assert_equal 12, replay.input_tokens
    assert_equal 7, replay.output_tokens
    assert_kind_of Integer, replay.duration_ms
    refute replay.errored?
    assert_equal "EvalsTest::OrdersAgent", replay.metadata["agent"]
    assert_equal "ask", replay.metadata["action"]
    assert_equal "Where is order ABC-123?", replay.metadata["prompt"]
    assert_equal "mock-orders", replay.metadata["model"]
  end

  test "every tool call is recorded with its arguments, result and timing" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(question: "Where is order ABC-123?").ask)

    assert_equal [ "lookup_order" ], replay.tool_names
    call = replay.tool_calls.first
    assert_equal({ "number" => "ABC-123" }, call["arguments"])
    assert_includes call["detail"], "shipped"
    assert_kind_of Integer, call["duration_ms"]
    refute call["error"]
    assert_empty replay.failed_tool_calls
  end

  test "a tool that raises is recorded as an error and the replay is errored" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(question: "Where is order BAD-1?").ask)

    assert replay.errored?
    assert_match(/no such order BAD-1/, replay.error)
    assert_nil replay.answer
    call = replay.tool_calls.first
    assert_equal "lookup_order", call["name"]
    assert call["error"]
    assert_match(/ArgumentError: no such order/, call["detail"])
    assert_equal [ call ], replay.failed_tool_calls
  end

  test "raise_errors re-raises instead of returning an errored replay" do
    error = assert_raises(ArgumentError) do
      Capture.run(EvalsTest::OrdersAgent.with(question: "Where is order BAD-1?").ask, raise_errors: true)
    end

    assert_match(/no such order/, error.message)
  end

  test "an action template renders the prompt as in any run" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(number: "XYZ-9").help)

    assert_equal "Where is order XYZ-9?", replay.metadata["prompt"]
    assert_equal "Order XYZ-9 is shipped.", replay.answer
    assert_equal [ "lookup_order" ], replay.tool_names
  end

  test "a tool served by a client-side MCP server is recorded like any other" do
    client = EvalsTest::FakeMCPClient.new
    replay = capture_mcp("fetch https://example.test", client)

    assert_equal [ "get_page" ], replay.tool_names
    call = replay.tool_calls.first
    assert_equal({ "url" => "https://example.test" }, call["arguments"])
    assert_includes call["detail"], "<html>Example</html>"
    assert_kind_of Integer, call["duration_ms"]
    refute call["error"]
    assert_empty replay.failed_tool_calls
    assert_equal "page <html>Example</html>", replay.answer
    assert_equal [ [ "get_page", { url: "https://example.test" } ] ], client.calls
  end

  test "a generation that calls a local tool and an MCP tool records each once" do
    client = EvalsTest::FakeMCPClient.new
    replay = capture_mcp("order ABC-123 then fetch https://example.test", client)

    assert_equal %w[lookup_order get_page], replay.tool_names
    assert_equal({ "number" => "ABC-123" }, replay.tool_calls.first["arguments"])
    assert_equal({ "url" => "https://example.test" }, replay.tool_calls.last["arguments"])
    assert_equal 1, client.calls.length
    assert_equal "order ABC-123 shipped; page <html>Example</html>", replay.answer
  end

  test "the same MCP tool called twice is two calls, each with its own result" do
    client = EvalsTest::FakeMCPClient.new(
      { "content" => [ { "type" => "text", "text" => "first" } ] },
      { "content" => [ { "type" => "text", "text" => "second" } ] }
    )
    replay = capture_mcp("fetch https://a.test fetch https://b.test", client)

    assert_equal %w[get_page get_page], replay.tool_names
    assert_equal [ "https://a.test", "https://b.test" ], replay.tool_calls.map { |call| call["arguments"]["url"] }
    assert_equal %w[first second], replay.tool_calls.map { |call| call["detail"] }
    assert_equal 2, client.calls.length
  end

  test "an MCP error result is a failed call, and the provider still receives it" do
    client = EvalsTest::FakeMCPClient.new(EvalsTest::FakeMCPClient::INVALID)
    replay = capture_mcp("fetch https://example.test", client)

    refute replay.errored?
    assert_equal [ "get_page" ], replay.tool_names
    call = replay.tool_calls.first
    assert call["error"]
    assert_equal "Invalid params", call["detail"]
    assert_equal [ call ], replay.failed_tool_calls
    assert_equal "page failed: Invalid params", replay.answer
    assert_equal 1, client.calls.length
  end

  test "an MCP tool that raises is recorded as an error and the replay is errored" do
    client = EvalsTest::FakeMCPClient.new(IOError.new("connection lost"))
    replay = capture_mcp("fetch https://example.test", client)

    assert replay.errored?
    assert_match(/IOError: connection lost/, replay.error)
    assert_equal [ "get_page" ], replay.tool_names
    call = replay.tool_calls.first
    assert_equal "get_page", call["name"]
    assert call["error"]
    assert_equal "IOError: connection lost", call["detail"]
    assert_kind_of Integer, call["duration_ms"]
  end

  test "raise_errors re-raises what an MCP tool raised" do
    client = EvalsTest::FakeMCPClient.new(IOError.new("connection lost"))

    assert_raises(IOError) { capture_mcp("fetch https://example.test", client, raise_errors: true) }
  end

  test "a result that merely has an error field is not an MCP failure" do
    client = EvalsTest::FakeMCPClient.new({ "structuredContent" => { "error" => "not found" } })
    replay = capture_mcp("fetch https://example.test", client)

    assert_equal [ "get_page" ], replay.tool_names
    refute replay.tool_calls.first["error"]
    assert_empty replay.failed_tool_calls
  end

  test "captures running side by side each keep their own MCP calls" do
    client = EvalsTest::FakeMCPClient.new
    replays = with_mcp_client(client) do
      %w[https://a.test https://b.test].map do |url|
        Thread.new { Capture.run(EvalsTest::MCPAgent.with(question: "fetch #{url}").ask) }
      end.map(&:value)
    end

    assert_equal [ [ "https://a.test" ], [ "https://b.test" ] ],
                 replays.map { |replay| replay.tool_calls.map { |call| call["arguments"]["url"] } }
    assert_equal 2, client.calls.length
  end

  test "an agent with no MCP servers is captured as before" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(question: "Where is order ABC-123?").ask)

    assert_equal [ "lookup_order" ], replay.tool_names
  end

  test "a model override runs the agent under that model and leaves the class alone" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(question: "Where is order ABC-123?").ask, model: "mock-other")

    assert_equal "mock-other", replay.metadata["model"]
    assert_equal "Order ABC-123 is shipped.", replay.answer
    assert_equal "mock-orders", EvalsTest::OrdersAgent.prompt_options[:model]
  end

  test "a provider override runs a subclass named as the agent, so its templates still resolve" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(number: "XYZ-9").help, provider: :mock, model: "mock-2")

    assert_equal "EvalsTest::OrdersAgent", replay.metadata["agent"]
    assert_equal "mock", replay.metadata["provider"]
    assert_equal "mock-2", replay.metadata["model"]
    # The plain mock provider answers in pig latin; what proves the template
    # rendered under the subclass is the prompt it recorded.
    assert_equal "Where is order XYZ-9?", replay.metadata["prompt"]
    assert replay.answer.present?
    assert_equal ActiveAgent::Providers::MockProvider, EvalsTest::OrdersAgent.prompt_provider_klass.superclass
  end

  test "retarget keeps the generation's params and action and carries the parent's instructions option" do
    parent = Class.new(ActiveAgent::Base) do
      def self.name = "EvalsTest::InstructedAgent"
      generate_with :mock, instructions: "Be brief."
      def ask = prompt(message: params[:question])
    end
    generation = parent.with(question: "hi").ask

    retargeted = Capture.retarget(generation, provider: :mock, model: "mock-3")

    assert_equal "EvalsTest::InstructedAgent", retargeted.agent_class.name
    assert_equal "Be brief.", retargeted.agent_class.prompt_options[:instructions]
    assert_equal "mock-3", retargeted.agent_class.prompt_options[:model]
    assert_equal :ask, retargeted.action_name
    assert_same generation, Capture.retarget(generation)
  end

  test "the block form accepts a response, a replay, a hash or a string" do
    from_response = Capture.run { EvalsTest::OrdersAgent.with(question: "Where is order ABC-123?").ask.generate_now }
    assert_equal "Order ABC-123 is shipped.", from_response.answer
    assert_equal 12, from_response.input_tokens
    assert_empty from_response.tool_calls, "nothing wraps an agent the block runs itself"

    from_replay = Capture.run(metadata: { "run" => 1 }) { Replay.new(answer: "ok", tool_calls: [ { "name" => "t" } ], metadata: { "chat" => 2 }) }
    assert_equal "ok", from_replay.answer
    assert_equal [ "t" ], from_replay.tool_names
    assert_equal({ "run" => 1, "chat" => 2 }, from_replay.metadata)
    assert_kind_of Integer, from_replay.duration_ms

    from_hash = Capture.run { { answer: "hash", output_tokens: 3 } }
    assert_equal "hash", from_hash.answer
    assert_equal 3, from_hash.output_tokens

    from_string = Capture.run { "plain" }
    assert_equal "plain", from_string.answer
  end

  test "a block that raises becomes an errored replay" do
    replay = Capture.run { raise "model down" }

    assert replay.errored?
    assert_equal "RuntimeError: model down", replay.error
  end

  test "a block that returns something else is the caller's bug" do
    assert_raises(ArgumentError) { Capture.run { 42 } }
    assert_raises(ArgumentError) { Capture.run }
  end

  test "tool arguments and results are recorded as JSON would carry them" do
    assert_equal({ "number" => "1", "nested" => { "a" => [ 1, 2 ] } }, Capture.jsonable({ number: "1", nested: { a: [ 1, 2 ] } }))
    assert_equal "short", Capture.preview("short")
    assert_equal Capture::DETAIL_LIMIT + 1, Capture.preview("x" * 1_000).length
    assert_equal '{"status":"shipped"}', Capture.preview({ status: "shipped" })
  end

  private

  # Runs EvalsTest::MCPAgent with a bridge over +client+ per generation, so no
  # transport opens. The bridge is the real one: it owns the tool, routes the
  # call and turns the client's answer into a result.
  def capture_mcp(question, client, **options)
    with_mcp_client(client) { Capture.run(EvalsTest::MCPAgent.with(question: question).ask, **options) }
  end

  def with_mcp_client(client, &test)
    servers = EvalsTest::MCPAgent.prompt_options[:mcps]
    build = lambda do |_declared, cache: nil|
      bridge = ActiveAgent::Providers::MCPBridge.allocate
      bridge.send(:initialize, servers, cache:)
      bridge.define_singleton_method(:connect) do |declaration|
        server = ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client:)
        @servers << server
        server
      end
      bridge
    end

    ActiveAgent::Providers::MCPToolCache.reset!
    ActiveAgent::Providers::MCPBridge.stub(:new, build, &test)
  ensure
    ActiveAgent::Providers::MCPToolCache.reset!
  end
end
