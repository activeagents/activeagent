# frozen_string_literal: true

module ActiveAgent
  module Streaming
    extend ActiveSupport::Concern

    class StreamChunk < Data.define(:delta, :stop)
    end

    attr_accessor :stream_chunk

    included do
      include ActiveSupport::Callbacks
      define_callbacks :stream, skip_after_callbacks_if_terminated: true
    end

    module ClassMethods
      # Defines a callback for handling streaming responses during generation
      def on_stream(*names, &blk)
        _insert_callbacks(names, blk) do |name, options|
          set_callback(:stream, :before, name, options)
        end
      end
    end

    # Helper method to run stream callbacks
    def run_stream_callbacks(message, delta = nil, stop = false)
      @stream_chunk = StreamChunk.new(delta, stop)
      run_callbacks(:stream) do
        yield(message, delta, stop) if block_given?
      end
    end
  end
end
