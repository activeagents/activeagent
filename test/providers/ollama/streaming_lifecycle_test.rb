# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/ollama_provider"

module Providers
  module Ollama
    class StreamingLifecycleTest < ActiveSupport::TestCase
      setup do
        @stream_events = []

        @provider = ActiveAgent::Providers::OllamaProvider.new(
          service: "Ollama",
          model: "llama3.2",
          messages: [ { role: "user", content: "Hello" } ],
          stream: true,
          stream_broadcaster: ->(message, delta, event_type) {
            @stream_events << { message: message, delta: delta, type: event_type }
          }
        )

        # Initialize message stack for streaming
        @provider.send(:message_stack).push({
          index: 0,
          role: "assistant",
          content: ""
        })
      end

      # Reuse OpenAI mock structures since Ollama inherits from OpenAI::ChatProvider
      MockChunk = Struct.new(:choices, keyword_init: true)
      MockChoice = Struct.new(:index, :delta, keyword_init: true)
      MockDelta = Struct.new(:content, :role, keyword_init: true) do
        def as_json
          { content: content, role: role }.compact
        end
      end

      MockChunkEvent = Struct.new(:type, :chunk, keyword_init: true)
      MockContentDoneEvent = Struct.new(:type, :content, :parsed, keyword_init: true)

      test "inherits streaming lifecycle from OpenAI::ChatProvider - emits :open event" do
        chunk = MockChunk.new(
          choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: "Hi", role: "assistant")) ]
        )
        event = MockChunkEvent.new(type: :chunk, chunk: chunk)

        @provider.send(:process_stream_chunk, event)

        open_events = @stream_events.select { |e| e[:type] == :open }
        assert_equal 1, open_events.size, "Ollama should emit :open event via inherited process_stream_chunk"
      end

      test "broadcast_stream_open is idempotent - only fires once" do
        3.times do
          chunk = MockChunk.new(
            choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: "x")) ]
          )
          event = MockChunkEvent.new(type: :chunk, chunk: chunk)
          @provider.send(:process_stream_chunk, event)
        end

        open_events = @stream_events.select { |e| e[:type] == :open }
        assert_equal 1, open_events.size, "Expected only one :open event even after multiple chunks"
      end

      test "full streaming lifecycle with Ollama role handling quirk" do
        # Ollama duplicates role in every delta - message_merge_delta handles this
        chunk1 = MockChunk.new(
          choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: "Hi", role: "assistant")) ]
        )
        @provider.send(:process_stream_chunk, MockChunkEvent.new(type: :chunk, chunk: chunk1))

        # Subsequent chunks also have role (Ollama bug/quirk)
        chunk2 = MockChunk.new(
          choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: " there", role: "assistant")) ]
        )
        @provider.send(:process_stream_chunk, MockChunkEvent.new(type: :chunk, chunk: chunk2))

        chunk3 = MockChunk.new(
          choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: "!", role: "assistant")) ]
        )
        @provider.send(:process_stream_chunk, MockChunkEvent.new(type: :chunk, chunk: chunk3))

        done_event = MockContentDoneEvent.new(
          type: :"content.done",
          content: "Hi there!",
          parsed: nil
        )

        # Stub process_prompt_finished to just call broadcast_stream_close
        @provider.stub(:process_prompt_finished, ->(*_) { @provider.send(:broadcast_stream_close) }) do
          @provider.send(:process_stream_chunk, done_event)
        end

        event_types = @stream_events.map { |e| e[:type] }

        assert_equal :open, event_types.first, "First event should be :open"
        assert_equal :close, event_types.last, "Last event should be :close"
        assert event_types.include?(:update), "Should have :update events"

        # Verify ordering
        open_index = event_types.index(:open)
        first_update_index = event_types.index(:update)
        close_index = event_types.index(:close)
        assert open_index < first_update_index, ":open should appear before first :update"
        assert first_update_index < close_index, ":update should appear before :close"
      end

      test "streaming flag is set to true after broadcast_stream_open" do
        refute @provider.send(:streaming), "streaming should be false initially"

        chunk = MockChunk.new(
          choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: "Hi")) ]
        )
        event = MockChunkEvent.new(type: :chunk, chunk: chunk)
        @provider.send(:process_stream_chunk, event)

        assert @provider.send(:streaming), "streaming should be true after open"
      end

      test "streaming flag is reset to false after broadcast_stream_close" do
        # Open the stream
        chunk = MockChunk.new(
          choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: "Hi", role: "assistant")) ]
        )
        @provider.send(:process_stream_chunk, MockChunkEvent.new(type: :chunk, chunk: chunk))

        assert @provider.send(:streaming), "streaming should be true after open"

        # Close the stream
        done_event = MockContentDoneEvent.new(
          type: :"content.done",
          content: "Hi",
          parsed: nil
        )

        # Stub process_prompt_finished to just call broadcast_stream_close
        @provider.stub(:process_prompt_finished, ->(*_) { @provider.send(:broadcast_stream_close) }) do
          @provider.send(:process_stream_chunk, done_event)
        end

        refute @provider.send(:streaming), "streaming should be false after close"
      end
    end
  end
end
