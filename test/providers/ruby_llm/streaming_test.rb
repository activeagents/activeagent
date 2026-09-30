# frozen_string_literal: true

require "test_helper"
require "ruby_llm"
require "active_agent/providers/ruby_llm_provider"
require_relative "ruby_llm_helper"

# What RubyLLMProvider does with the chunks ruby_llm parses out of a real
# streamed response. The server-sent events are what each API sends; parsing
# them into chunks is ruby_llm's, and what comes out is the provider's.
#
# Providers stream a tool call's arguments as fragments of one JSON string,
# and only the first fragment says which call it belongs to: it carries the
# call's ID and name, and the rest carry neither.
class RubyLLMStreamingTest < ActiveSupport::TestCase
  include WebMock::API
  include RubyLLMHelper
  extend RubyLLMHelper

  WEATHER_TOOL = {
    type: "function",
    function: {
      name: "get_weather",
      description: "Current weather for a city",
      parameters: { type: "object", properties: { city: { type: "string" } }, required: [ "city" ] }
    }
  }.freeze

  # Builds the streams of one API: endpoint, model, provider options, and the
  # request-side view of a replayed tool call.
  class Stream
    FRAGMENTS = 3

    # The OpenAI protocol to pin, nil for an API that has only one.
    def protocol = nil

    def events(*payloads, named: false)
      payloads.map do |payload|
        event = named ? "event: #{payload[:type]}\n" : ""
        "#{event}data: #{payload.to_json}\n\n"
      end.join
    end

    # The JSON of a call's arguments in a few pieces, split mid-token the way
    # a model streams them.
    def fragments(arguments)
      size = (arguments.length / FRAGMENTS.to_f).ceil
      arguments.scan(/.{1,#{size}}/m)
    end
  end

  class ChatCompletions < Stream
    def name = :chat_completions
    def model = "gpt-4o-mini"
    def endpoint = "https://api.openai.com/v1/chat/completions"
    def protocol = :chat_completions

    # counted: false leaves out the usage chunk, as a server that does not
    # report usage does.
    def text(*deltas, counted: true)
      usage = { model: model, choices: [], usage: { prompt_tokens: 12, completion_tokens: 4,
                                                    prompt_tokens_details: { cached_tokens: 5 },
                                                    completion_tokens_details: { reasoning_tokens: 2 } } }

      body(*deltas.map { |delta| chunk({ content: delta }) }, chunk({}, finish: "stop"), *(counted ? [ usage ] : []))
    end

    def tool_calls(*calls)
      chunks = calls.each_with_index.flat_map do |call, index|
        [ chunk({ role: "assistant", content: nil, tool_calls: [ { index: index, id: call[:id], type: "function",
                                                                   function: { name: call[:name], arguments: "" } } ] }) ] +
          fragments(call[:arguments]).map do |fragment|
            chunk({ tool_calls: [ { index: index, function: { arguments: fragment } } ] })
          end
      end

      body(*chunks, chunk({}, finish: "tool_calls"))
    end

    def interleaved_tool_calls(*calls)
      openings = calls.each_with_index.map do |call, index|
        { index: index, id: call[:id], type: "function", function: { name: call[:name], arguments: "" } }
      end
      pieces = calls.map { |call| fragments(call[:arguments]) }
      deltas = pieces.first.zip(*pieces.drop(1)).map do |row|
        chunk({ tool_calls: row.each_with_index.map { |fragment, index| { index: index, function: { arguments: fragment } } } })
      end

      body(chunk({ tool_calls: openings }), *deltas, chunk({}, finish: "tool_calls"))
    end

    # [name, arguments] of each tool call the request repeats.
    def replayed_tool_calls(request)
      request["messages"].flat_map { |message| message["tool_calls"] || [] }.map do |call|
        [ call.dig("function", "name"), JSON.parse(call.dig("function", "arguments")) ]
      end
    end

    private

    def body(*chunks)
      events(*chunks) + "data: [DONE]\n\n"
    end

    def chunk(delta, finish: nil)
      { id: "chatcmpl-stream", object: "chat.completion.chunk", model: model,
        choices: [ { index: 0, delta: delta, finish_reason: finish } ] }
    end
  end

  class Responses < Stream
    def name = :responses
    def model = "gpt-4o-mini"
    def endpoint = "https://api.openai.com/v1/responses"
    def protocol = :responses

    def text(*deltas)
      events(
        *deltas.map { |delta| { type: "response.output_text.delta", output_index: 0, content_index: 0, delta: delta } },
        completed([ { type: "message", role: "assistant", content: [ { type: "output_text", text: deltas.join } ] } ]),
        named: true
      )
    end

    def tool_calls(*calls)
      items = calls.map do |call|
        { type: "function_call", call_id: call[:id], name: call[:name], arguments: call[:arguments], status: "completed" }
      end
      streamed = calls.each_with_index.flat_map do |call, index|
        [ { type: "response.output_item.added", output_index: index,
            item: { type: "function_call", call_id: call[:id], name: call[:name], arguments: "" } } ] +
          fragments(call[:arguments]).map do |fragment|
            { type: "response.function_call_arguments.delta", output_index: index, delta: fragment }
          end
      end

      events(*streamed, completed(items), named: true)
    end

    def replayed_tool_calls(request)
      request["input"].select { |item| item["type"] == "function_call" }.map do |call|
        [ call["name"], JSON.parse(call["arguments"]) ]
      end
    end

    private

    def completed(output)
      { type: "response.completed",
        response: { model: model, status: "completed", output: output, usage: { input_tokens: 12, output_tokens: 4 } } }
    end
  end

  class Anthropic < Stream
    def name = :anthropic
    def model = "claude-haiku-4-5"
    def endpoint = "https://api.anthropic.com/v1/messages"

    def text(*deltas)
      events(
        message_start,
        { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
        *deltas.map { |delta| { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: delta } } },
        { type: "content_block_stop", index: 0 },
        message_delta("end_turn"),
        { type: "message_stop" },
        named: true
      )
    end

    def tool_calls(*calls)
      blocks = calls.each_with_index.flat_map do |call, index|
        [ { type: "content_block_start", index: index,
            content_block: { type: "tool_use", id: call[:id], name: call[:name], input: {} } } ] +
          fragments(call[:arguments]).map do |fragment|
            { type: "content_block_delta", index: index, delta: { type: "input_json_delta", partial_json: fragment } }
          end +
          [ { type: "content_block_stop", index: index } ]
      end

      events(message_start, *blocks, message_delta("tool_use"), { type: "message_stop" }, named: true)
    end

    def replayed_tool_calls(request)
      request["messages"].flat_map { |message| Array(message["content"]) }
                         .select { |block| block.is_a?(Hash) && block["type"] == "tool_use" }
                         .map { |block| [ block["name"], block["input"] ] }
    end

    private

    def message_start
      { type: "message_start",
        message: { id: "msg_stream", type: "message", role: "assistant", model: model, content: [],
                   stop_reason: nil, usage: { input_tokens: 12, output_tokens: 1 } } }
    end

    def message_delta(stop_reason)
      { type: "message_delta", delta: { stop_reason: stop_reason, stop_sequence: nil }, usage: { output_tokens: 4 } }
    end
  end

  STREAMS = [ ChatCompletions.new, (Responses.new if ruby_llm_2?), Anthropic.new ].compact.freeze
  ANTHROPIC_STREAM = STREAMS.last

  setup do
    @original_keys = RubyLLM.config.openai_api_key, RubyLLM.config.anthropic_api_key
    @original_openai_protocol = RubyLLM.config.openai_protocol if RubyLLM.config.respond_to?(:openai_protocol)
    RubyLLM.configure do |config|
      config.openai_api_key = "test-openai-key"
      config.anthropic_api_key = "test-anthropic-key"
    end
  end

  teardown do
    RubyLLM.config.openai_api_key, RubyLLM.config.anthropic_api_key = @original_keys
    RubyLLM.config.openai_protocol = @original_openai_protocol if RubyLLM.config.respond_to?(:openai_protocol)
  end

  STREAMS.each do |stream|
    test "streams the text of a response (#{stream.name})" do
      pin_protocol(stream)
      stub_streams(stream.endpoint, stream.text("It's ", "72F."))

      deltas = []
      broadcaster = ->(_message, delta, type) { deltas << delta if type == :update }
      response = streaming_provider(stream, stream_broadcaster: broadcaster).prompt

      assert_equal [ "It's ", "72F." ], deltas
      assert_equal "It's 72F.", response.messages.last.content
    end

    test "preserves streamed usage and the final stop reason (#{stream.name})" do
      pin_protocol(stream)
      stub_streams(stream.endpoint, stream.text("Done."))

      response = streaming_provider(stream).prompt

      assert_not_nil response.usage
      assert_equal(stream.name == :chat_completions ? 7 : 12, response.usage.input_tokens)
      assert_equal 4, response.usage.output_tokens
      assert_equal "end_turn", response.finish_reason
      assert_equal "Done.", response.messages.last.content
      assert_equal 1, response.messages.count { |message| message.role == "assistant" }
      if stream.name == :chat_completions
        assert_equal 5, response.usage.cached_tokens
        assert_equal 2, response.usage.reasoning_tokens
      end
    end

    test "runs a tool once, with the arguments streamed across fragments (#{stream.name})" do
      pin_protocol(stream)
      requests = stub_streams(stream.endpoint,
        stream.tool_calls({ id: "call_1", name: "get_weather", arguments: '{"city":"Boston"}' }),
        stream.text("It's 72F."))

      calls = []
      response = streaming_provider(stream, tools_function: recording(calls)).prompt

      assert_equal [ [ "get_weather", { city: "Boston" } ] ], calls
      assert_equal "It's 72F.", response.messages.last.content
      assert_equal [ [ "get_weather", { "city" => "Boston" } ] ], stream.replayed_tool_calls(requests.last)
    end

    test "runs each of several streamed tool calls once, with its own arguments (#{stream.name})" do
      pin_protocol(stream)
      requests = stub_streams(stream.endpoint,
        stream.tool_calls({ id: "call_1", name: "get_weather", arguments: '{"city":"Boston"}' },
                          { id: "call_2", name: "get_weather", arguments: '{"city":"Denver"}' }),
        stream.text("Boston is 72F and Denver 65F."))

      calls = []
      response = streaming_provider(stream, tools_function: recording(calls)).prompt

      assert_equal [ [ "get_weather", { city: "Boston" } ], [ "get_weather", { city: "Denver" } ] ], calls
      assert_equal "Boston is 72F and Denver 65F.", response.messages.last.content
      assert_equal [ [ "get_weather", { "city" => "Boston" } ], [ "get_weather", { "city" => "Denver" } ] ],
                   stream.replayed_tool_calls(requests.last)
    end
  end

  test "reports no usage for a stream whose server counted no tokens" do
    stream = STREAMS.first
    pin_protocol(stream)
    stub_streams(stream.endpoint, stream.text("Done.", counted: false))

    response = streaming_provider(stream).prompt

    assert_equal "Done.", response.messages.last.content
    assert_equal "end_turn", response.finish_reason
    assert_nil response.usage
  end

  # A turn that ends in tool calls is tool_use, whether its chunks say so
  # (ruby_llm 1.16 has no finish reason to read) or end with :stop while the
  # calls arrived in earlier chunks, as in OpenAI's Responses API.
  test "a streamed turn that ends in tool calls is tool_use" do
    call = ->(id) { ::RubyLLM::ToolCall.new(id: id, name: "get_weather", arguments: '{"city":"Boston"}') }
    scripted = ScriptedProvider.new(
      [ ::RubyLLM::Chunk.new(role: :assistant, content: nil, tool_calls: { 0 => call.("call_1") }) ],
      [ ::RubyLLM::Chunk.new(role: :assistant, content: "Done.") ]
    )

    assert_equal [ "tool_use", "end_turn" ], turn_stop_reasons(scripted)
  end

  test "a streamed turn whose calls came before its :stop finish chunk is tool_use" do
    skip_unless_ruby_llm_2!("Chunk#finish_reason")
    call = ::RubyLLM::ToolCall.new(id: "call_1", name: "get_weather", arguments: '{"city":"Boston"}')
    scripted = ScriptedProvider.new(
      [ ::RubyLLM::Chunk.new(role: :assistant, content: nil, tool_calls: { 0 => call }),
        ::RubyLLM::Chunk.new(role: :assistant, content: nil, finish_reason: :stop) ],
      [ ::RubyLLM::Chunk.new(role: :assistant, content: "Done.", finish_reason: :stop) ]
    )

    assert_equal [ "tool_use", "end_turn" ], turn_stop_reasons(scripted)
  end

  test "keeps interleaved Chat Completions tool fragments separate through the real parser" do
    skip_unless_ruby_llm_2!("stream indices for interleaved OpenAI tool calls")
    stream = STREAMS.first
    pin_protocol(stream)
    requests = stub_streams(stream.endpoint,
      stream.interleaved_tool_calls({ id: "call_1", name: "get_weather", arguments: '{"city":"Boston"}' },
                                    { id: "call_2", name: "get_weather", arguments: '{"city":"Denver"}' }),
      stream.text("Done."))
    calls = []

    response = streaming_provider(stream, tools_function: recording(calls)).prompt

    assert_equal [ [ "get_weather", { city: "Boston" } ], [ "get_weather", { city: "Denver" } ] ], calls
    assert_equal "Done.", response.message.content
    assert_equal [ [ "get_weather", { "city" => "Boston" } ], [ "get_weather", { "city" => "Denver" } ] ],
                 stream.replayed_tool_calls(requests.last)
  end

  # --- Fragments as ruby_llm hands them over ---
  #
  # A chunk of a streamed tool call is keyed by the index the API numbers its
  # calls by (nil in ruby_llm 1.16 for OpenAI's fragments), and has an ID and
  # name only on the chunk that starts the call.

  test "adds each fragment to the tool call with the same stream key" do
    calls = run_streamed_tools(
      tool_chunk(0, id: "call_a", name: "get_weather", arguments: ""),
      tool_chunk(1, id: "call_b", name: "get_weather", arguments: ""),
      tool_chunk(0, arguments: '{"city":'),
      tool_chunk(1, arguments: '{"city":"Denver"}'),
      tool_chunk(0, arguments: '"Boston"}')
    )

    assert_equal [ { city: "Boston" }, { city: "Denver" } ], calls.map(&:last)
  end

  test "adds a fragment without a stream key to the latest tool call" do
    calls = run_streamed_tools(
      tool_chunk("call_a", id: "call_a", name: "get_weather", arguments: ""),
      tool_chunk(nil, arguments: '{"city":'),
      tool_chunk(nil, arguments: '"Boston"}'),
      tool_chunk("call_b", id: "call_b", name: "get_weather", arguments: ""),
      tool_chunk(nil, arguments: '{"city":"Denver"}')
    )

    assert_equal [ [ "get_weather", { city: "Boston" } ], [ "get_weather", { city: "Denver" } ] ], calls
  end

  test "adds to a tool call each time a chunk names it again" do
    calls = run_streamed_tools(
      tool_chunk("call_1", id: "call_1", name: "get_weather", arguments: '{"city":'),
      tool_chunk("call_1", id: "call_1", name: "get_weather", arguments: '"Boston"}')
    )

    assert_equal [ [ "get_weather", { city: "Boston" } ] ], calls
  end

  # Anthropic opens a tool call with an empty Hash for its input; Gemini sends
  # the arguments whole, as a Hash.
  test "starts a tool call from an empty Hash of arguments" do
    calls = run_streamed_tools(
      tool_chunk(0, id: "toolu_1", name: "get_weather", arguments: {}),
      tool_chunk(0, arguments: '{"city":"Boston"}')
    )

    assert_equal [ [ "get_weather", { city: "Boston" } ] ], calls
  end

  test "reads tool call arguments sent whole as a Hash" do
    calls = run_streamed_tools(tool_chunk("call_1", id: "call_1", name: "get_weather", arguments: { city: "Boston" }))

    assert_equal [ [ "get_weather", { city: "Boston" } ] ], calls
  end

  test "keeps a call with no arguments as one with none" do
    calls = run_streamed_tools(tool_chunk(0, id: "call_1", name: "get_weather", arguments: ""))

    assert_equal [ [ "get_weather", {} ] ], calls
  end

  test "merges partial cumulative usage without counting repeated chunks twice across tool turns" do
    first = tool_chunk(0, id: "call_1", name: "get_weather", arguments: '{"city":"Boston"}')
    counts = ->(**attributes) {
      ::RubyLLM::Chunk.new(role: :assistant, content: nil, **ruby_llm_token_attributes(**attributes))
    }
    scripted = ScriptedProvider.new(
      [ first, counts.call(input: 10, output: 1, cache_read: 5), counts.call(output: 3), counts.call(output: 3) ],
      [ ::RubyLLM::Chunk.new(role: :assistant, content: "Done."), counts.call(input: 7, output: 2, thinking: 1) ]
    )

    with_ruby_llm_provider(scripted) do
      response = streaming_provider(ANTHROPIC_STREAM).prompt

      assert_not_nil response.usage
      assert_equal 17, response.usage.input_tokens
      assert_equal 5, response.usage.output_tokens
      assert_equal 5, response.usage.cached_tokens
      assert_equal 1, response.usage.reasoning_tokens
      assert_equal "end_turn", response.finish_reason
    end
  end

  test "preserves a streamed token limit stop after a trailing chunk without metadata" do
    skip_unless_ruby_llm_2!("Chunk#finish_reason")
    scripted = ScriptedProvider.new([
      ::RubyLLM::Chunk.new(role: :assistant, content: "Partial.", finish_reason: :max_tokens),
      ::RubyLLM::Chunk.new(role: :assistant, content: nil)
    ])

    with_ruby_llm_provider(scripted) do
      response = streaming_provider(ANTHROPIC_STREAM).prompt

      assert_equal "max_tokens", response.finish_reason
      assert_nil response.usage
      assert_equal "Partial.", response.messages.last.content
    end
  end

  private

  # The stop reason each turn of a streamed tool loop reported, as the
  # instrumentation event of its prompt request saw it.
  def turn_stop_reasons(scripted)
    reasons = []
    subscriber = ActiveSupport::Notifications.subscribe("prompt.provider.active_agent") do |*, payload|
      reasons << payload[:finish_reason]
    end

    with_ruby_llm_provider(scripted) do
      streaming_provider(ANTHROPIC_STREAM, tools_function: ->(*, **) { { temp: 72 } }).prompt
    end

    reasons
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # ruby_llm 1.16 has only Chat Completions, and no protocol to configure.
  def pin_protocol(stream)
    RubyLLM.config.openai_protocol = stream.protocol if stream.protocol && ruby_llm_2?
  end

  def tool_chunk(key, id: nil, name: nil, arguments: "")
    ::RubyLLM::Chunk.new(role: :assistant, content: nil,
                         tool_calls: { key => ::RubyLLM::ToolCall.new(id: id, name: name, arguments: arguments) })
  end

  # Streams the chunks as one turn that ends in text, and returns the
  # [name, arguments] of each tool call the provider ran.
  def run_streamed_tools(*chunks)
    calls = []
    provider = ScriptedProvider.new(chunks, [ ::RubyLLM::Chunk.new(role: :assistant, content: "Done.") ])

    with_ruby_llm_provider(provider) do
      streaming_provider(ANTHROPIC_STREAM, tools_function: recording(calls)).prompt
    end

    calls
  end

  def streaming_provider(stream, tools_function: ->(_name, **_arguments) { { temp: 72 } },
                         stream_broadcaster: ->(_message, _delta, _type) { }, **options)
    ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: stream.model,
      messages: [ { role: "user", content: "Weather in Boston?" } ],
      tools: [ WEATHER_TOOL ],
      tools_function: tools_function,
      stream: true,
      stream_broadcaster: stream_broadcaster,
      **options
    )
  end

  # A tools_function that notes each call it gets and answers the weather.
  def recording(calls)
    ->(name, **arguments) {
      calls << [ name, arguments ]
      { temp: 72 }
    }
  end

  # Answers successive requests to endpoint with the event streams, in order,
  # and returns the list the parsed request bodies are collected into.
  def stub_streams(endpoint, *streams)
    requests = []
    queue = streams.dup

    stub_request(:post, endpoint).to_return do |request|
      requests << JSON.parse(request.body)
      { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: queue.shift }
    end

    requests
  end
end
