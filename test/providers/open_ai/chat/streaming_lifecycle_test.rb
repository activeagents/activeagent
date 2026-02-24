# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/active_agent/providers/open_ai/chat_provider"

module Providers
  module OpenAI
    module Chat
      class StreamingLifecycleTest < ActiveSupport::TestCase
        setup do
          @stream_events = []

          @provider = ActiveAgent::Providers::OpenAI::ChatProvider.new(
            service: "OpenAI",
            model: "gpt-4o-mini",
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

        # Mock event structures that match OpenAI's streaming API
        MockChunk = Struct.new(:choices, keyword_init: true)
        MockChoice = Struct.new(:index, :delta, keyword_init: true)
        MockDelta = Struct.new(:content, :role, keyword_init: true) do
          def as_json
            { content: content, role: role }.compact
          end
        end

        MockChunkEvent = Struct.new(:type, :chunk, keyword_init: true)
        MockContentDoneEvent = Struct.new(:type, :content, :parsed, keyword_init: true)

        test "process_stream_chunk emits :open event on first chunk" do
          chunk = MockChunk.new(
            choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: "Hi", role: "assistant")) ]
          )
          event = MockChunkEvent.new(type: :chunk, chunk: chunk)

          @provider.send(:process_stream_chunk, event)

          open_events = @stream_events.select { |e| e[:type] == :open }
          assert_equal 1, open_events.size, "Expected exactly one :open event"
        end

        test "process_stream_chunk emits :update events for content" do
          %w[Hi there !].each do |content|
            chunk = MockChunk.new(
              choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: content)) ]
            )
            event = MockChunkEvent.new(type: :chunk, chunk: chunk)
            @provider.send(:process_stream_chunk, event)
          end

          update_events = @stream_events.select { |e| e[:type] == :update }
          assert_equal 3, update_events.size, "Expected three :update events"
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

        test "content.done event triggers :close via process_prompt_finished" do
          # First send a chunk to trigger :open
          chunk = MockChunk.new(
            choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: "Hi", role: "assistant")) ]
          )
          chunk_event = MockChunkEvent.new(type: :chunk, chunk: chunk)
          @provider.send(:process_stream_chunk, chunk_event)

          # Then send content.done event which triggers process_prompt_finished
          done_event = MockContentDoneEvent.new(
            type: :"content.done",
            content: "Hi there!",
            parsed: nil
          )

          # Stub process_prompt_finished to just call broadcast_stream_close
          # This avoids the nil request issue while testing the streaming lifecycle
          @provider.stub(:process_prompt_finished, ->(*_) { @provider.send(:broadcast_stream_close) }) do
            @provider.send(:process_stream_chunk, done_event)
          end

          close_events = @stream_events.select { |e| e[:type] == :close }
          assert_equal 1, close_events.size, "Expected exactly one :close event"
        end

        test "full streaming lifecycle emits open, update, and close in correct order" do
          # First chunk with role
          chunk1 = MockChunk.new(
            choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: "Hi", role: "assistant")) ]
          )
          @provider.send(:process_stream_chunk, MockChunkEvent.new(type: :chunk, chunk: chunk1))

          # Additional content chunks
          chunk2 = MockChunk.new(
            choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: " there")) ]
          )
          @provider.send(:process_stream_chunk, MockChunkEvent.new(type: :chunk, chunk: chunk2))

          chunk3 = MockChunk.new(
            choices: [ MockChoice.new(index: 0, delta: MockDelta.new(content: "!")) ]
          )
          @provider.send(:process_stream_chunk, MockChunkEvent.new(type: :chunk, chunk: chunk3))

          # Content done event
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
          assert event_types.count(:update) >= 3, "Should have at least 3 :update events"

          # Verify :open appears before first :update
          open_index = event_types.index(:open)
          first_update_index = event_types.index(:update)
          assert open_index < first_update_index, ":open should appear before first :update"

          # Verify last :update appears before :close
          last_update_index = event_types.rindex(:update)
          close_index = event_types.index(:close)
          assert last_update_index < close_index, "last :update should appear before :close"
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
end
