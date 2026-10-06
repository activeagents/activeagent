# frozen_string_literal: true

require "test_helper"
require "mcp"
require "active_agent/providers/deepseek_provider"
require "active_agent/providers/anthropic_provider"
require "active_agent/providers/ollama_provider"
require "active_agent/providers/open_router_provider"
require "active_agent/providers/ruby_llm_provider"

# How `mcps:` is split between the provider and the bridge.
#
# The bridge is the universal path — every provider supports `mcps:`, whether or
# not its API does — and a provider that *can* serve a server itself keeps doing
# so, because its own tool loop costs nothing in prompt tokens. The two are not
# exclusive: a provider that speaks MCP for remote servers still needs the bridge
# for a local one, since nothing but this process is going to spawn that.
class MCPBridgeWiringTest < ActiveSupport::TestCase
  AnthropicProvider  = ActiveAgent::Providers::AnthropicProvider
  ResponsesProvider  = ActiveAgent::Providers::OpenAI::ResponsesProvider
  DeepSeekProvider   = ActiveAgent::Providers::DeepSeekProvider
  OllamaProvider     = ActiveAgent::Providers::OllamaProvider
  OpenRouterProvider = ActiveAgent::Providers::OpenRouterProvider
  RubyLLMProvider    = ActiveAgent::Providers::RubyLLMProvider

  URL_SERVER     = [ { name: "firecrawl", url: "https://mcp.example.com/mcp" } ].freeze
  COMMAND_SERVER = [ { name: "local", command: "mcp-server", args: [ "--stdio" ] } ].freeze
  BOTH_SERVERS   = (URL_SERVER + COMMAND_SERVER).freeze
  MESSAGES       = [ { role: "user", content: "Fetch https://example.com" } ].freeze
  ARCHIVE_TOOL   = { name: "archive", description: "Archive a file", parameters: { type: "object", properties: {} } }.freeze

  ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages"
  DEEPSEEK_ENDPOINT  = "https://api.deepseek.com/chat/completions"

  # Offers one tool, and answers a call to it with `answer`: a tool result, or
  # an error to raise, as the real client raises on a JSON-RPC error. How the
  # bridge reads each answer is covered by MCPBridgeTest; here it is followed
  # into the request the provider sends next.
  class FakeClient
    def initialize(answer: { "content" => [ { "type" => "text", "text" => "<html></html>" } ] })
      @answer = answer
    end

    def tools
      [ MCP::Client::Tool.new(name: "get_page", description: "Fetch a page", input_schema: nil) ]
    end

    # @return [Hash] the JSON-RPC envelope, which is what the real client returns
    def call_tool(name:, arguments:)
      raise @answer if @answer.is_a?(Exception)

      { "jsonrpc" => "2.0", "id" => 1, "result" => @answer }
    end
  end

  # The cache is process-global; see MCPBridgeTest.
  setup    { ActiveAgent::Providers::MCPToolCache.reset! }
  teardown { ActiveAgent::Providers::MCPToolCache.reset! }

  test "only Anthropic and OpenAI Responses can serve MCP themselves" do
    assert_equal [ :url ], provider(AnthropicProvider).mcp_native_transports
    assert_equal [ :url ], provider(ResponsesProvider).mcp_native_transports
  end

  test "the OpenAI-compatible providers have no MCP of their own" do
    [ DeepSeekProvider, OllamaProvider, OpenRouterProvider, RubyLLMProvider ].each do |klass|
      assert_empty provider(klass).mcp_native_transports, "#{klass.service_name} should have no native MCP"
    end
  end

  test "every provider bridges a remote server it cannot serve" do
    [ DeepSeekProvider, OllamaProvider, OpenRouterProvider, RubyLLMProvider ].each do |klass|
      with_bridge do
        context = provider(klass, mcps: URL_SERVER).send(:prompt_context)

        assert_not context.key?(:mcps), "#{klass.service_name} cannot accept the declaration"
        assert_not context.key?(:mcp_strategy), "the strategy instructs us; no provider accepts it"
        assert_equal [ "get_page" ], context[:tools].pluck(:name)
      end
    end
  end

  test "Anthropic keeps a remote server native" do
    context = provider(AnthropicProvider, mcps: URL_SERVER).send(:prompt_context)

    assert_equal URL_SERVER, context[:mcps]
    assert_nil context[:tools], "a natively served server must not add tool schemas"
  end

  # Anthropic cannot be handed a process to run, so a local server is the
  # bridge's job even there.
  test "Anthropic bridges a local server" do
    with_bridge do
      context = provider(AnthropicProvider, mcps: COMMAND_SERVER).send(:prompt_context)

      assert_not context.key?(:mcps)
      assert_equal [ "get_page" ], context[:tools].pluck(:name)
    end
  end

  test "Anthropic splits a mixed declaration" do
    with_bridge do
      context = provider(AnthropicProvider, mcps: BOTH_SERVERS).send(:prompt_context)

      assert_equal URL_SERVER, context[:mcps], "the remote server stays with the provider"
      assert_equal [ "get_page" ], context[:tools].pluck(:name), "the local one is bridged"
    end
  end

  test "mcp_strategy: :client runs a remote server client-side even on Anthropic" do
    with_bridge do
      context = provider(AnthropicProvider, mcps: URL_SERVER, mcp_strategy: :client).send(:prompt_context)

      assert_not context.key?(:mcps)
      assert_equal [ "get_page" ], context[:tools].pluck(:name)
    end
  end

  test "mcp_strategy: :server refuses what the provider cannot serve" do
    error = assert_raises(ArgumentError) do
      provider(AnthropicProvider, mcps: COMMAND_SERVER, mcp_strategy: :server).send(:prompt_context)
    end

    assert_includes error.message, "command"
    assert_includes error.message, ":url"
  end

  test "mcp_strategy: :server names the absence when the provider has no MCP" do
    error = assert_raises(ArgumentError) do
      provider(DeepSeekProvider, mcps: URL_SERVER, mcp_strategy: :server).send(:prompt_context)
    end

    assert_includes error.message, "none"
  end

  test "serves a String-keyed declaration natively where the provider can" do
    declared = [ { "name" => "firecrawl", "url" => "https://mcp.example.com/mcp" } ]

    context = provider(AnthropicProvider, mcps: declared).send(:prompt_context)

    assert_equal URL_SERVER, context[:mcps]
    assert_nil context[:tools], "a natively served server must not add tool schemas"
  end

  test "refuses an mcp_strategy it does not know" do
    error = assert_raises(ArgumentError) do
      provider(AnthropicProvider, mcps: URL_SERVER, mcp_strategy: :native).send(:prompt_context)
    end

    assert_includes error.message, ":auto, :client, :server"
    assert_includes error.message, ":native"
  end

  # The approval gate sits in the provider's tool loop, which never sees the
  # calls of a server the provider runs itself.
  test "Anthropic and OpenAI Responses run a remote server client-side when its calls need approval" do
    [ AnthropicProvider, ResponsesProvider ].each do |klass|
      [ "always", { never: { tool_names: [ "get_page" ] } }, { always: [ "get_page" ] } ].each do |policy|
        with_bridge do
          context = provider(klass, mcps: [ URL_SERVER.first.merge(require_approval: policy) ]).send(:prompt_context)

          assert_not context.key?(:mcps), "#{klass.service_name} must not serve a server with require_approval #{policy.inspect}"
          assert_equal [ "get_page" ], context[:tools].pluck(:name)
        end
      end
    end
  end

  test "require_approval: never keeps a remote server native" do
    [ AnthropicProvider, ResponsesProvider ].each do |klass|
      declaration = URL_SERVER.first.merge(require_approval: "never")
      context     = provider(klass, mcps: [ declaration ]).send(:prompt_context)

      assert_equal [ declaration ], context[:mcps]
    end
  end

  test "a remote server is run client-side when requires_approval: names one of its allowed_tools" do
    declaration = URL_SERVER.first.merge(allowed_tools: [ "get_page" ])

    with_bridge do
      context = provider(AnthropicProvider, mcps: [ declaration ], requires_approval: [ :get_page ]).send(:prompt_context)

      assert_not context.key?(:mcps)
      assert_not context.key?(:requires_approval), "the approval list instructs us; no provider accepts it"
    end
  end

  test "a remote server without allowed_tools is run client-side when requires_approval: names a tool no declared tool has" do
    [ AnthropicProvider, ResponsesProvider ].each do |klass|
      with_bridge do
        context = provider(klass, mcps: URL_SERVER, tools: [ ARCHIVE_TOOL ], requires_approval: %i[archive delete]).send(:prompt_context)

        assert_not context.key?(:mcps), "#{klass.service_name} could run delete where nobody is asked to approve it"
      end
    end
  end

  test "a remote server stays native when requires_approval: names only declared tools, in either tool format" do
    chat_format = { type: "function", function: { name: "archive", description: "Archive a file", parameters: {} } }

    [ ARCHIVE_TOOL, chat_format ].each do |tool|
      ActiveAgent::Providers::MCPBridge.stub(:new, ->(*) { flunk "a server that offers no named tool is not bridged" }) do
        context = provider(AnthropicProvider, mcps: URL_SERVER, tools: [ tool ], requires_approval: [ :archive ]).send(:prompt_context)

        assert_equal URL_SERVER, context[:mcps]
      end
    end
  end

  test "a remote server whose allowed_tools leave out every named tool stays native" do
    declaration = URL_SERVER.first.merge(allowed_tools: [ "get_page" ])

    ActiveAgent::Providers::MCPBridge.stub(:new, ->(*) { flunk "a server that cannot offer delete is not bridged" }) do
      context = provider(ResponsesProvider, mcps: [ declaration ], requires_approval: [ :delete ]).send(:prompt_context)

      assert_equal [ declaration ], context[:mcps]
    end
  end

  test "a require_approval map that covers no tool keeps a remote server native" do
    declaration = URL_SERVER.first.merge(require_approval: { always: [] })

    assert_equal [ declaration ], provider(AnthropicProvider, mcps: [ declaration ]).send(:prompt_context)[:mcps]
  end

  test "mcp_strategy: :server refuses a remote server that may offer a tool requires_approval: names" do
    [ AnthropicProvider, ResponsesProvider ].each do |klass|
      error = assert_raises(ArgumentError) do
        provider(klass, mcps: URL_SERVER, requires_approval: [ :delete ], mcp_strategy: :server).send(:prompt_context)
      end
      assert_includes error.message, "`requires_approval:` names delete"
      assert_includes error.message, "List the tools it may offer in `allowed_tools:`"

      declaration = URL_SERVER.first.merge(allowed_tools: %w[get_page delete])
      error = assert_raises(ArgumentError) do
        provider(klass, mcps: [ declaration ], requires_approval: [ :delete ], mcp_strategy: :server).send(:prompt_context)
      end
      assert_includes error.message, "Remove delete from its `allowed_tools:`"
    end
  end

  test "mcp_strategy: :server refuses a server whose calls need approval" do
    error = assert_raises(ArgumentError) do
      provider(ResponsesProvider, mcps: [ URL_SERVER.first.merge(require_approval: "always") ], mcp_strategy: :server).send(:prompt_context)
    end

    assert_includes error.message, "need approval"
  end

  test "keeps the agent's own tools alongside the bridge's" do
    declared = { name: "local_tool", description: "Local", parameters: {} }

    with_bridge do
      context = provider(DeepSeekProvider, mcps: URL_SERVER, tools: [ declared ]).send(:prompt_context)

      assert_equal %w[local_tool get_page], context[:tools].pluck(:name)
    end
  end

  test "a provider with no mcps: is untouched" do
    subject = provider(DeepSeekProvider)

    assert_nil subject.send(:mcp_bridge)
    assert_equal subject.context, subject.send(:prompt_context)
  end

  test "strips mcp_cache from the provider request context" do
    with_bridge do
      context = provider(DeepSeekProvider, mcps: URL_SERVER, mcp_cache: false).send(:prompt_context)

      assert_not context.key?(:mcp_cache), "cache policy is an ActiveAgent setting, not an API parameter"
    end
  end

  test "a single declaration is accepted without an array" do
    with_bridge do
      context = provider(DeepSeekProvider, mcps: URL_SERVER.first).send(:prompt_context)

      assert_equal [ "get_page" ], context[:tools].pluck(:name)
    end
  end

  # A preview must not do I/O — discovering MCP tools means connecting to the
  # servers — so a bridged server cannot appear in one.
  test "a preview bridges nothing" do
    ActiveAgent::Providers::MCPBridge.stub(:new, ->(*) { fail "the bridge must not be built for a preview" }) do
      context = provider(DeepSeekProvider, mcps: URL_SERVER).send(:preview_context)

      assert_not context.key?(:mcps)
      assert_nil context[:tools]
    end
  end

  test "a preview keeps a server the provider serves natively" do
    ActiveAgent::Providers::MCPBridge.stub(:new, ->(*) { fail "the bridge must not be used for a native server" }) do
      context = provider(AnthropicProvider, mcps: URL_SERVER).send(:preview_context)

      assert_equal URL_SERVER, context[:mcps]
    end
  end

  # A bridged server holds a live connection, and for a `command:` server that
  # connection is a process. It has to be released when the generation that
  # opened it finishes — the garbage collector would never reap it, so a
  # long-lived worker would accumulate orphans.
  test "releases the bridge once the generation finishes" do
    with_bridge do |bridge|
      closes = track_close(bridge)

      # A local, because `define_singleton_method` runs its block with the
      # provider as `self`, so the test's own helpers are out of scope there.
      response = response_double

      subject = provider(DeepSeekProvider, mcps: URL_SERVER)
      subject.define_singleton_method(:resolve_prompt) { response }

      subject.prompt

      assert_equal 1, closes.size, "the connections must be closed, not left to the garbage collector"
      assert_nil subject.send(:mcp_bridge)
    end
  end

  test "releases the bridge when the generation raises" do
    with_bridge do |bridge|
      closes = track_close(bridge)

      subject = provider(DeepSeekProvider, mcps: URL_SERVER)
      subject.define_singleton_method(:resolve_prompt) { raise "the provider exploded" }

      error = assert_raises(RuntimeError) { subject.prompt }

      assert_equal "the provider exploded", error.message
      assert_equal 1, closes.size, "a failed generation must not leave its connections open"
    end
  end

  test "releases an earlier bridge when a later call on the same provider replaces it" do
    with_bridge do |bridge|
      closes = track_close(bridge)

      subject = provider(DeepSeekProvider, mcps: URL_SERVER)
      subject.send(:prompt_context)
      subject.send(:prompt_context)

      assert_equal 1, closes.size, "the first bridge must be released when the second replaces it"
    end
  end

  # Discovery connects to the servers while the request is still being built, so
  # a failure in between would otherwise strand every connection it opened.
  test "releases the bridge when the request cannot be built" do
    with_bridge do |bridge|
      closes = track_close(bridge)

      failing = Object.new
      failing.define_singleton_method(:cast) { |*| raise "cannot build the request" }

      subject = provider(DeepSeekProvider, mcps: URL_SERVER)
      subject.define_singleton_method(:prompt_request_type) { failing }

      error = assert_raises(RuntimeError) { subject.prompt }

      assert_equal "cannot build the request", error.message
      assert_equal 1, closes.size, "the connection was opened before the request, so it must still be released"
    end
  end

  # A call that fails on a bridged server has to reach the model as a failure,
  # or it reads the error as the tool's answer. Anthropic's tool result has a
  # flag for that, which stays false for a tool the agent declares itself.
  test "Anthropic flags a call that failed on a bridged server, and only that call" do
    failure = { "content" => [ { "type" => "text", "text" => "Rate limit exceeded" } ], "isError" => true }
    local   = { name: "local_tool", description: "Local", parameters: { type: "object", properties: {} } }

    with_bridge(FakeClient.new(answer: failure)) do
      bodies = stub_responses(
        ANTHROPIC_ENDPOINT,
        anthropic_response(stop_reason: "tool_use", content: [
          { type: "tool_use", id: "toolu_1", name: "get_page", input: { url: "https://example.com" } },
          { type: "tool_use", id: "toolu_2", name: "local_tool", input: {} }
        ]),
        anthropic_response(content: [ { type: "text", text: "The page could not be fetched." } ])
      )

      provider(AnthropicProvider, model: "claude-haiku-4-5", mcps: COMMAND_SERVER, tools: [ local ],
               tools_function: ->(*, **) { { ok: true } }).prompt

      results = bodies.last["messages"].last["content"]

      assert_equal [ true, false ], results.pluck("is_error")
      assert_equal [ '{"error":"Rate limit exceeded"}', '{"ok":true}' ], results.pluck("content")
    end
  end

  # An OpenAI-compatible tool message has no error flag, so its content is all
  # the model has to go on.
  test "DeepSeek sends a call that failed on a bridged server as an error" do
    failure = MCP::Client::ServerError.new("Invalid params: url must be a string", code: -32_602)

    with_bridge(FakeClient.new(answer: failure)) do
      bodies = stub_responses(
        DEEPSEEK_ENDPOINT,
        openai_response(tool_calls: [
          { id: "call_1", type: "function", function: { name: "get_page", arguments: '{"url":1}' } }
        ]),
        openai_response(content: "The page could not be fetched.")
      )

      provider(DeepSeekProvider, mcps: URL_SERVER).prompt

      tool_message = bodies.last["messages"].find { |message| message["role"] == "tool" }

      assert_equal '{"error":"Invalid params: url must be a string"}', tool_message["content"]
    end
  end

  private

  # Builds a provider. A request it sends can only reach a WebMock stub, so the
  # placeholder key is never checked.
  def provider(klass, **kwargs)
    klass.new({ service: klass.service_name, api_key: "test", messages: MESSAGES }.merge(kwargs))
  end

  # Replaces the bridge the provider builds with one whose `connect` is stubbed,
  # so no transport is opened. The stand-in is yielded, so a test can watch what
  # a generation does to it.
  def with_bridge(client = FakeClient.new, &test)
    bridge = ActiveAgent::Providers::MCPBridge.new(URL_SERVER)
    bridge.define_singleton_method(:connect) do |declaration|
      server = ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client:)

      instance_variable_get(:@servers) << server
      server
    end

    # A lambda, not the bridge itself: Minitest's `stub` calls a value that
    # responds to `call`, and the bridge has a public `call` method of its own.
    ActiveAgent::Providers::MCPBridge.stub(:new, ->(*) { bridge }) { test.call(bridge) }
  end

  # Replaces the bridge's `close` with a recorder. The stubbed `connect` opens no
  # transport, so the real `close` would have nothing to act on.
  #
  # @return [Array] appended to once per close
  def track_close(bridge)
    closes = []
    bridge.define_singleton_method(:close) do
      closes << :closed
      nil
    end

    closes
  end

  # A real response, not a stub: the instrumentation path reads `usage`,
  # `finish_reason`, `model` and `id` straight off it.
  def response_double
    ActiveAgent::Providers::Common::PromptResponse.new(raw_response: {})
  end

  # Answers successive requests to `endpoint` with `responses`, in order, and
  # returns the list the parsed request bodies are collected into.
  def stub_responses(endpoint, *responses)
    bodies = []
    queue  = responses.dup

    stub_request(:post, endpoint).to_return do |request|
      bodies << JSON.parse(request.body)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: queue.shift.to_json }
    end

    bodies
  end

  def anthropic_response(content:, stop_reason: "end_turn")
    {
      id: "msg_bridge", type: "message", role: "assistant", model: "claude-haiku-4-5",
      content:, stop_reason:, stop_sequence: nil, usage: { input_tokens: 12, output_tokens: 4 }
    }
  end

  def openai_response(content: nil, tool_calls: nil)
    message = { role: "assistant", content: }
    message[:tool_calls] = tool_calls if tool_calls

    {
      id: "chatcmpl-bridge", object: "chat.completion", created: 0, model: "deepseek-flash",
      choices: [ { index: 0, message:, finish_reason: tool_calls ? "tool_calls" : "stop" } ],
      usage: { prompt_tokens: 12, completion_tokens: 4, total_tokens: 16 }
    }
  end
end
