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
      # # Defines a callback that will get called right before/after/around the
      # # generation provider method.
      [ :before, :after, :around ].each do |callback|
        define_method "#{callback}_generation" do |*names, &blk|
          _insert_callbacks(names, blk) do |name, options|
            set_callback(:generation, callback, name, options)
          end
        end
      end

      # Defines a callback for handling streaming responses during generation
      def on_stream(*names, &blk)
        _insert_callbacks(names, blk) do |name, options|
          set_callback(:stream, :before, name, options)
        end
      end
    end

    # Helper method to run stream callbacks
    def run_stream_callbacks(message, delta = nil, stop = false)
      run_callbacks(:stream) do
        yield(message, delta, stop) if block_given?
      end
    end
  end
end
