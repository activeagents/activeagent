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

  # Only the tool list is needed here — the call path is covered by
  # MCPBridgeTest.
  class FakeClient
    def tools
      [ MCP::Client::Tool.new(name: "get_page", description: "Fetch a page", input_schema: nil) ]
    end
  end

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

  private

  # Builds a provider whose `mcps:` partitioning is then exercised directly. No
  # request is ever sent, so the placeholder key is never used.
  def provider(klass, **kwargs)
    klass.new({ service: klass.service_name, api_key: "test", messages: MESSAGES }.merge(kwargs))
  end

  # Replaces the bridge the provider builds with one whose `connect` is stubbed,
  # so no transport is opened.
  def with_bridge(&)
    client = FakeClient.new

    bridge = ActiveAgent::Providers::MCPBridge.new(URL_SERVER)
    bridge.define_singleton_method(:connect) do |declaration|
      ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client:)
    end

    # A lambda, not the bridge itself: Minitest's `stub` calls a value that
    # responds to `call`, and the bridge has a public `call` method of its own.
    ActiveAgent::Providers::MCPBridge.stub(:new, ->(*) { bridge }, &)
  end
end
