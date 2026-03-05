# frozen_string_literal: true

require "test_helper"

GEMINI_STREAMING_OPENAI_AVAILABLE = begin
  require "openai"
  true
rescue LoadError
  warn "OpenAI gem not available, skipping Gemini streaming lifecycle tests"
  false
end

require_relative "../../../lib/active_agent/providers/gemini_provider" if GEMINI_STREAMING_OPENAI_AVAILABLE

module Providers
  module Gemini
    class StreamingLifecycleTest < ActiveSupport::TestCase
      setup do
        skip "OpenAI gem not available" unless GEMINI_STREAMING_OPENAI_AVAILABLE
        @stream_events = []

        @provider = ActiveAgent::Providers::GeminiProvider.new(
          service: "Gemini",
          api_key: "test-api-key",
          model: "gemini-2.0-flash",
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

      # Reuse OpenAI mock structures since Gemini inherits from OpenAI::ChatProvider
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
        assert_equal 1, open_events.size, "Gemini should emit :open event via inherited process_stream_chunk"
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

      test "message_merge_delta handles Gemini role duplication correctly" do
        # Gemini sends role in every streaming chunk (unlike OpenAI which only sends it in first chunk)
        # This test verifies the role is not concatenated (e.g., "assistantassistant")

        message = {}

        # First chunk sets the role
        delta1 = { role: "assistant", content: "Hi" }
        result = @provider.send(:message_merge_delta, message, delta1)
        assert_equal "assistant", result[:role]
        assert_equal "Hi", result[:content]

        # Second chunk also has role (Gemini behavior)
        delta2 = { role: "assistant", content: " there" }
        result = @provider.send(:message_merge_delta, result, delta2)

        # Role should NOT be "assistantassistant"
        assert_equal "assistant", result[:role], "Role should not be concatenated"
        assert_equal "Hi there", result[:content], "Content should be concatenated"

        # Third chunk
        delta3 = { role: "assistant", content: "!" }
        result = @provider.send(:message_merge_delta, result, delta3)

        assert_equal "assistant", result[:role], "Role should still be 'assistant'"
        assert_equal "Hi there!", result[:content]
      end

      test "full streaming lifecycle with Gemini role handling" do
        # Gemini duplicates role in every delta - message_merge_delta handles this
        chunk1 = MockChunk.new(
          choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: "Hi", role: "assistant")) ]
        )
        @provider.send(:process_stream_chunk, MockChunkEvent.new(type: :chunk, chunk: chunk1))

        # Subsequent chunks also have role (Gemini behavior)
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

        # Verify role is not corrupted in final message
        final_message = @provider.send(:message_stack).last
        assert_equal "assistant", final_message[:role], "Final message role should be 'assistant', not concatenated"
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

      test "process_stream_chunk emits :update events for content" do
        %w[Hi there !].each do |content|
          chunk = MockChunk.new(
            choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: content, role: "assistant")) ]
          )
          event = MockChunkEvent.new(type: :chunk, chunk: chunk)
          @provider.send(:process_stream_chunk, event)
        end

        update_events = @stream_events.select { |e| e[:type] == :update }
        assert_equal 3, update_events.size, "Expected three :update events"
      end
    end
  end
end
