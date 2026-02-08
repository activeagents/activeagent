# frozen_string_literal: true

module ActiveAgent
  # Provides streaming callback support for agent classes.
  #
  # Callbacks can be registered for three points in the streaming lifecycle:
  # - {on_stream_open} - invoked before the first chunk
  # - {on_stream} - invoked for every chunk received
  # - {on_stream_close} - invoked after the final chunk
  #
  # Callbacks automatically receive a {StreamChunk} parameter if they accept arguments.
  #
  # @example Basic usage with chunk parameter
  #   class MyPrompt < ActiveAgent::Base
  #     on_stream_open :setup_stream
  #     on_stream :log_chunk
  #     on_stream_close :cleanup_stream
  #
  #     private
  #
  #     def setup_stream(chunk)
  #       puts "Stream opening..."
  #       puts "First message: #{chunk.message}"
  #     end
  #
  #     def log_chunk(chunk)
  #       print chunk.delta if chunk.delta
  #     end
  #
  #     def cleanup_stream(chunk)
  #       puts "\nStream complete!"
  #     end
  #   end
  #
  # @example Usage without chunk parameter
  #   class MyPrompt < ActiveAgent::Base
  #     on_stream_open :initialize_counter
  #     on_stream :increment_counter
  #     on_stream_close :log_total
  #
  #     private
  #
  #     def initialize_counter
  #       @count = 0
  #     end
  #
  #     def increment_counter
  #       @count += 1
  #     end
  #
  #     def log_total
  #       puts "Total chunks: #{@count}"
  #     end
  #   end
  #
  # @example Using blocks
  #   class MyPrompt < ActiveAgent::Base
  #     on_stream do |chunk|
  #       Rails.logger.info("Received: #{chunk.delta}")
  #     end
  #   end
  #
  # @example With callback options
  #   class MyPrompt < ActiveAgent::Base
  #     on_stream :log_chunk, if: :debug_mode?
  #     on_stream_close :save_response, unless: :test_environment?
  #   end
  module Streaming
    extend ActiveSupport::Concern

    # Data object representing a chunk of streamed content.
    #
    # @!attribute [r] message
    #   @return [Object] the complete message object from the provider
    # @!attribute [r] delta
    #   @return [String, nil] the incremental content delta for this chunk
    class StreamChunk < Data.define(:message, :delta); end

    included do
      include AbstractController::Callbacks

      define_callbacks :stream_open
      define_callbacks :stream
      define_callbacks :stream_close

      # Internal attribute to store the current streaming chunk.
      #
      # @api private
      attr_internal :stream_chunk
    end

    class_methods do
      # Defines a callback for when streaming opens.
      #
      # Invoked before the first chunk. Callbacks receive a {StreamChunk}
      # if they accept arguments.
      #
      # @param names [Symbol] method names to call as callbacks
      # @param block [Proc] optional block to execute as a callback
      # @yield [chunk] passes the {StreamChunk} if the block accepts parameters
      # @yieldparam chunk [StreamChunk] current stream chunk
      # @option options [Symbol, Proc] :if condition for running the callback
      # @option options [Symbol, Proc] :unless condition for skipping the callback
      # @return [void]
      #
      # @example With method that accepts chunk
      #   on_stream_open :setup_streaming
      #
      #   def setup_streaming(chunk)
      #     @buffer = []
      #     Rails.logger.info("Starting: #{chunk.message}")
      #   end
      #
      # @example With method that doesn't need chunk
      #   on_stream_open :initialize_buffer
      #
      #   def initialize_buffer
      #     @buffer = []
      #   end
      #
      # @example With a block
      #   on_stream_open do |chunk|
      #     Rails.logger.info("Stream opening with message: #{chunk.message}")
      #   end
      #
      # @example With conditions
      #   on_stream_open :log_open, if: :logging_enabled?
      def on_stream_open(*names, &block)
        _stream_define_callback(:stream_open, *names, &block)
      end

      # Defines a callback for handling streaming responses.
      #
      # Invoked for every chunk received. Callbacks receive a {StreamChunk}
      # if they accept arguments.
      #
      # @param names [Symbol] method names to call as callbacks
      # @param block [Proc] optional block to execute as a callback
      # @yield [chunk] passes the {StreamChunk} if the block accepts parameters
      # @yieldparam chunk [StreamChunk] current stream chunk
      # @option options [Symbol, Proc] :if condition for running the callback
      # @option options [Symbol, Proc] :unless condition for skipping the callback
      # @return [void]
      #
      # @example With method that accepts chunk
      #   on_stream :process_chunk
      #
      #   def process_chunk(chunk)
      #     print chunk.delta if chunk.delta
      #   end
      #
      # @example With method that doesn't need chunk
      #   on_stream :increment_counter
      #
      #   def increment_counter
      #     @chunk_count += 1
      #   end
      #
      # @example With a block
      #   on_stream do |chunk|
      #     print chunk.delta if chunk.delta
      #   end
      #
      # @example With conditions
      #   on_stream :buffer_chunk, unless: :direct_output?
      def on_stream(*names, &block)
        _stream_define_callback(:stream, *names, &block)
      end

      # Defines a callback for when streaming closes.
      #
      # Invoked after the final chunk. Callbacks receive a {StreamChunk}
      # if they accept arguments.
      #
      # @param names [Symbol] method names to call as callbacks
      # @param block [Proc] optional block to execute as a callback
      # @yield [chunk] passes the {StreamChunk} if the block accepts parameters
      # @yieldparam chunk [StreamChunk] current stream chunk
      # @option options [Symbol, Proc] :if condition for running the callback
      # @option options [Symbol, Proc] :unless condition for skipping the callback
      # @return [void]
      #
      # @example With method that accepts chunk
      #   on_stream_close :save_response
      #
      #   def save_response(chunk)
      #     Rails.logger.info("Complete: #{chunk.message}")
      #   end
      #
      # @example With method that doesn't need chunk
      #   on_stream_close :cleanup
      #
      #   def cleanup
      #     @buffer = nil
      #   end
      #
      # @example With a block
      #   on_stream_close do |chunk|
      #     Rails.logger.info("Stream complete")
      #   end
      #
      # @example With conditions
      #   on_stream_close :persist_response, if: :should_save?
      def on_stream_close(*names, &block)
        _stream_define_callback(:stream_close, *names, &block)
      end

      # @api private
      # @param callback_name [Symbol] callback type (:stream_open, :stream, :stream_close)
      # @param names [Array<Symbol>] method names or procs to register
      # @param block [Proc] optional block to register
      # @return [void]
      def _stream_define_callback(callback_name, *names, &block)
        _insert_callbacks(names, block) do |name, options|
          wrapper = _stream_define_callback_wrapper(callback_name, name)
          set_callback(callback_name, :before, wrapper, **options)
        end
      end

      # @api private
      # @param callback_name [Symbol] callback type
      # @param method_ref [Symbol, Proc] method name or proc to wrap
      # @return [Symbol] wrapper method name
      def _stream_define_callback_wrapper(callback_name, method_ref)
        if method_ref.is_a?(Proc)
          _stream_define_callback_wrapper_proc(callback_name, method_ref)
        else
          _stream_define_callback_wrapper_name(callback_name, method_ref)
        end
      end

      # @api private
      # @param callback_name [Symbol] callback type
      # @param method_name [Symbol] method name to wrap
      # @return [Symbol] wrapper method name
      def _stream_define_callback_wrapper_name(callback_name, method_name)
        define_method(:"_#{callback_name}_#{method_name}") do
          if method(method_name).arity.zero?
            send(method_name)
          else
            send(method_name, stream_chunk)
          end
        end
      end

      # @api private
      # @param callback_name [Symbol] callback type
      # @param method_proc [Proc] proc to wrap
      # @return [Symbol] wrapper method name
      def _stream_define_callback_wrapper_proc(callback_name, method_proc)
        define_method(:"_#{callback_name}_#{method_proc.object_id}") do
          if method_proc.arity.zero?
            instance_exec(&method_proc)
          else
            instance_exec(stream_chunk, &method_proc)
          end
        end
      end
    end

    private

    # Returns a proc that runs streaming callbacks for provider execution.
    #
    # The returned proc creates a {StreamChunk} and triggers callbacks
    # based on the type parameter (`:open`, `:update`, or `:close`).
    #
    # @return [Proc] callback proc that accepts (message, delta, type)
    def stream_broadcaster
      proc do |message, delta, type|
        cast_message = message.is_a?(Hash) ? Providers::Common::Messages::Types::MessageType.new.cast(message) : message
        self.stream_chunk = StreamChunk.new(cast_message, delta)

        run_callbacks(:stream_open) if type == :open
        run_callbacks(:stream)
        run_callbacks(:stream_close) if type == :close

        # Don't leak dirty context between callbacks or into userspace
        self.stream_chunk = nil
      end
    end
  end
end
