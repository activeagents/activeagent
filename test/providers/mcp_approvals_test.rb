# frozen_string_literal: true

require "test_helper"
require "mcp"
require_relative "../../lib/active_agent/providers/anthropic_provider"
require_relative "../../lib/active_agent/providers/open_ai/responses_provider"

# Approving MCP tool calls. A server whose calls need approval runs
# client-side, so its calls go through the provider's tool loop and pause
# before they reach the server. The requests go over the Anthropic Messages
# wire format, and over OpenAI Responses where noted; the MCP servers are
# stand-ins.
class MCPApprovalsTest < ActiveSupport::TestCase
  include WebMock::API

  # A server Anthropic runs itself goes to the beta Messages endpoint.
  ENDPOINT = %r{\Ahttps://api\.anthropic\.com/v1/messages}
  FILES    = { name: "files", url: "https://files.example.com/mcp", require_approval: "always" }.freeze

  # Stands in for a connected MCP client.
  class FakeClient
    attr_reader :calls

    def initialize(*names)
      @names = names
      @calls = []
    end

    def tools
      @names.map { MCP::Client::Tool.new(name: _1, description: "#{_1} a file", input_schema: { type: "object", properties: { path: { type: "string" } } }) }
    end

    def call_tool(name:, arguments:)
      @calls << [ name, arguments ]

      { "jsonrpc" => "2.0", "id" => 1, "result" => { "content" => [ { "type" => "text", "text" => "#{name} done" } ] } }
    end
  end

  class FilesAgent < ApplicationAgent
    generate_with :anthropic, model: "claude-sonnet-4-5", api_key: "test-key"

    class_attribute :calls, default: []

    def tidy
      prompt(message: "Delete the draft", mcps: params.fetch(:mcps, [ FILES ]), **params.fetch(:options, {}))
    end

    def archive(path:)
      calls << [ :archive, path ]
      { archived: path }
    end
  end

  # The same agent on OpenAI Responses, which can also serve a url server
  # itself.
  class ResponsesFilesAgent < FilesAgent
    generate_with :openai, model: "gpt-5-mini", api_key: "test-key"
  end

  RESPONSES_ENDPOINT = "https://api.openai.com/v1/responses"

  DELETE  = { type: "tool_use", id: "toolu_1", name: "delete", input: { path: "draft.md" } }.freeze
  ARCHIVE = { type: "tool_use", id: "toolu_2", name: "archive", input: { path: "notes.md" } }.freeze
  DONE    = { type: "text", text: "Done." }.freeze

  ARCHIVE_TOOL = { name: "archive", description: "Archive a file",
                   parameters: { type: "object", properties: { path: { type: "string" } }, required: [ "path" ] } }.freeze

  setup do
    ActiveAgent::Providers::MCPToolCache.reset!
    FilesAgent.calls = []
    @clients = { "files" => FakeClient.new("delete") }
  end

  teardown { ActiveAgent::Providers::MCPToolCache.reset! }

  def assistant_message(*content)
    stop_reason = content.any? { |block| block[:type] == "tool_use" } ? "tool_use" : "end_turn"

    { id: "msg_#{SecureRandom.hex(4)}", type: "message", role: "assistant", model: "claude-sonnet-4-5",
      content:, stop_reason:, stop_sequence: nil, usage: { input_tokens: 20, output_tokens: 10 } }
  end

  def stub_messages(*messages)
    @request_bodies = []
    stub_request(:post, ENDPOINT)
      .with { |request| @request_bodies << JSON.parse(request.body) }
      .to_return(*messages.map { { status: 200, headers: { "Content-Type" => "application/json" }, body: _1.to_json } })
  end

  attr_reader :request_bodies

  # Builds every bridge with connections to the stand-in clients, so no
  # transport is opened.
  def with_fake_servers(&test)
    clients = @clients
    build = lambda do |servers, cache: nil|
      bridge = ActiveAgent::Providers::MCPBridge.allocate
      bridge.send(:initialize, servers, cache:)
      bridge.define_singleton_method(:connect) do |declaration|
        server = ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client: clients.fetch(declaration[:name].to_s))
        @servers << server
        server
      end
      bridge
    end

    ActiveAgent::Providers::MCPBridge.stub(:new, build, &test)
  end

  def generation(**params) = FilesAgent.with(**params).tidy

  def resume(paused, answers, **params)
    generation(**params).resume_now(checkpoint: JSON.parse(paused.checkpoint.to_json), answers:)
  end

  def tool_results(body)
    body["messages"].last["content"].map { [ _1["tool_use_id"], _1["content"] ] }
  end

  test "a url server that requires approval runs client-side, and its call pauses before it reaches the server" do
    stub_messages(assistant_message(DELETE))

    paused = with_fake_servers { generation.generate_now }

    assert paused.awaiting_input?
    request = paused.input_requests.sole
    assert_equal [ :confirm, "delete", { "path" => "draft.md" } ], [ request.kind, request.tool_name, request.arguments ]
    assert_equal({ "approval" => true }, request.metadata)
    assert_empty @clients["files"].calls
    assert_not request_bodies.first.key?("mcp_servers"), "the server is not handed to Anthropic"
    assert_equal [ "delete" ], request_bodies.first["tools"].pluck("name")
  end

  test "an approved call runs on the server once, after the server is connected again" do
    stub_messages(assistant_message(DELETE), assistant_message(DONE))
    paused = with_fake_servers { generation.generate_now }

    response = with_fake_servers { resume(paused, { "toolu_1" => true }) }

    assert_equal "Done.", response.message.content
    assert_equal [ [ "delete", { path: "draft.md" } ] ], @clients["files"].calls
    assert_equal [ [ "toolu_1", "delete done".to_json ] ], tool_results(request_bodies.last)
  end

  test "a declined call never reaches the server" do
    stub_messages(assistant_message(DELETE), assistant_message(DONE))
    paused = with_fake_servers { generation.generate_now }

    with_fake_servers { resume(paused, { "toolu_1" => false }) }

    assert_empty @clients["files"].calls
    assert_equal [ [ "toolu_1", ActiveAgent::InputRequest::DECLINED_RESULT.to_json ] ], tool_results(request_bodies.last)
  end

  test "an approved call to a tool the server no longer offers returns an error without calling it" do
    stub_messages(assistant_message(DELETE), assistant_message(DONE))
    paused = with_fake_servers { generation.generate_now }

    @clients["files"] = FakeClient.new("rename")
    ActiveAgent::Providers::MCPToolCache.reset!
    with_fake_servers { resume(paused, { "toolu_1" => true }) }

    assert_empty @clients["files"].calls
    assert_equal [ [ "toolu_1", { error: "delete is no longer offered by its MCP server" }.to_json ] ], tool_results(request_bodies.last)
  end

  test "require_approval: never keeps a url server with Anthropic" do
    stub_messages(assistant_message(DONE))

    ActiveAgent::Providers::MCPBridge.stub(:new, ->(*) { flunk "a server that needs no approval is not bridged" }) do
      generation(mcps: [ FILES.merge(require_approval: "never") ]).generate_now
    end

    assert_equal [ "files" ], request_bodies.first["mcp_servers"].pluck("name")
  end

  test "requires_approval: gates an agent tool and a bridged MCP tool in the same turn" do
    @clients = { "files" => FakeClient.new("delete") }
    files    = FILES.except(:require_approval)
    params   = { mcps: [ files ], options: { tools: [ ARCHIVE_TOOL ], requires_approval: %w[archive delete], mcp_strategy: :client } }
    stub_messages(assistant_message(DELETE, ARCHIVE), assistant_message(DONE))

    paused = with_fake_servers { generation(**params).generate_now }

    assert_equal %w[delete archive], paused.input_requests.map(&:tool_name)
    assert_empty @clients["files"].calls
    assert_empty FilesAgent.calls

    with_fake_servers { resume(paused, { "toolu_1" => true, "toolu_2" => false }, **params) }

    assert_equal [ [ "delete", { path: "draft.md" } ] ], @clients["files"].calls
    assert_empty FilesAgent.calls
    assert_equal [ "toolu_1", "toolu_2" ], tool_results(request_bodies.last).map(&:first)
  end

  test "requires_approval: naming one of a url server's allowed_tools runs that server client-side" do
    files = FILES.except(:require_approval).merge(allowed_tools: [ "delete" ])
    stub_messages(assistant_message(DELETE))

    paused = with_fake_servers { generation(mcps: [ files ], options: { requires_approval: [ "delete" ] }).generate_now }

    assert paused.awaiting_input?
    assert_not request_bodies.first.key?("mcp_servers")
  end

  test "requires_approval: naming a tool no declared tool has runs a url server without allowed_tools client-side" do
    files = FILES.except(:require_approval)
    stub_messages(assistant_message(DELETE))

    paused = with_fake_servers { generation(mcps: [ files ], options: { requires_approval: [ "delete" ] }).generate_now }

    request = paused.input_requests.sole
    assert_equal [ :confirm, "delete" ], [ request.kind, request.tool_name ]
    assert_empty @clients["files"].calls
    assert_not request_bodies.first.key?("mcp_servers"), "Anthropic would run delete where nobody is asked to approve it"
  end

  test "mcp_strategy: :server refuses a url server that may offer a tool requires_approval: names, before any request" do
    files = FILES.except(:require_approval)
    stub_messages(assistant_message(DONE))

    error = assert_raises(ArgumentError) do
      generation(mcps: [ files ], options: { requires_approval: [ "delete" ], mcp_strategy: :server }).generate_now
    end

    assert_includes error.message, "`requires_approval:` names delete"
    assert_not_requested :post, ENDPOINT
  end

  def responses_body(*output)
    { id: "resp_#{SecureRandom.hex(4)}", object: "response", created_at: 1_761_502_994, status: "completed", model: "gpt-5-mini",
      output:, usage: { input_tokens: 20, output_tokens: 10, total_tokens: 30 } }
  end

  test "on OpenAI Responses, a url server that requires approval runs client-side, and an approved call runs once" do
    delete = { type: "function_call", id: "fc_1", call_id: "call_1", name: "delete", arguments: { path: "draft.md" }.to_json, status: "completed" }
    done   = { type: "message", id: "msg_1", role: "assistant", status: "completed", content: [ { type: "output_text", text: "Done.", annotations: [] } ] }
    @request_bodies = []
    stub_request(:post, RESPONSES_ENDPOINT)
      .with { |request| @request_bodies << JSON.parse(request.body) }
      .to_return(*[ responses_body(delete), responses_body(done) ].map { { status: 200, headers: { "Content-Type" => "application/json" }, body: _1.to_json } })

    paused = with_fake_servers { ResponsesFilesAgent.with(mcps: [ FILES ]).tidy.generate_now }

    request = paused.input_requests.sole
    assert_equal [ :confirm, "delete", { "path" => "draft.md" } ], [ request.kind, request.tool_name, request.arguments ]
    assert_empty @clients["files"].calls
    assert_equal [ [ "function", "delete" ] ], request_bodies.first["tools"].map { _1.values_at("type", "name") },
                 "the server is not handed to OpenAI as an mcp tool"

    response = with_fake_servers do
      ResponsesFilesAgent.with(mcps: [ FILES ]).tidy.resume_now(checkpoint: JSON.parse(paused.checkpoint.to_json), answers: { "call_1" => true })
    end

    assert_equal "Done.", response.message.content
    assert_equal [ [ "delete", { path: "draft.md" } ] ], @clients["files"].calls
    output = request_bodies.last["input"].find { _1["type"] == "function_call_output" }
    assert_equal [ "call_1", "delete done".to_json ], output.values_at("call_id", "output")
  end

  test "mcp_strategy: :server refuses a server whose calls need approval, before any request" do
    stub_messages(assistant_message(DONE))

    error = assert_raises(ArgumentError) { generation(options: { mcp_strategy: :server }).generate_now }

    assert_match "need approval", error.message
    assert_not_requested :post, ENDPOINT
  end
end
