# frozen_string_literal: true

module ActiveAgent
  module Callbacks
    extend ActiveSupport::Concern

    included do
      include ActiveSupport::Callbacks
      define_callbacks :generation, skip_after_callbacks_if_terminated: true
      define_callbacks :stream, skip_after_callbacks_if_terminated: true
    end

    module ClassMethods
      # Defines a callback that will get called right before the
      # prompt is sent to the generation provider method.
      def before_generation(*filters, &blk)
        set_callback(:generation, :before, *filters, &blk)
      end

      # Defines a callback that will get called right after the
      # prompt's generation method is finished.
      def after_generation(*filters, &blk)
        set_callback(:generation, :after, *filters, &blk)
      end

      # Defines a callback that will get called around the prompt's generation method.
      def around_generation(*filters, &blk)
        set_callback(:generation, :around, *filters, &blk)
      end

      # Defines a callback for handling streaming responses during generation
      def on_stream(*filters, &blk)
        set_callback(:stream, :before, *filters, &blk)
      end
    end

    # Helper method to run stream callbacks
    def run_stream_callbacks(message, delta = nil, stop = false)
      # Store the parameters in instance variables so callbacks can access them
      @_stream_message = message
      @_stream_delta = delta
      @_stream_stop = stop
      
      run_callbacks(:stream) do
        yield(message, delta, stop) if block_given?
      end
    ensure
      # Clean up the instance variables
      @_stream_message = nil
      @_stream_delta = nil
      @_stream_stop = nil
    end
  end
end
