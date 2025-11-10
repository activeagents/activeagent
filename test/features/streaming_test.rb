# frozen_string_literal: true

require "test_helper"

class StreamingTest < ActiveSupport::TestCase
  # Test class that includes the Streaming concern
  class TestAgent
    include ActiveAgent::Streaming

    attr_reader :chunks_received, :callbacks_log

    def initialize
      @chunks_received = []
      @callbacks_log = []
    end

    on_stream_open :on_open
    on_stream :on_chunk
    on_stream_close :on_close

    private

    def on_open(chunk)
      @callbacks_log << :open
    end

    def on_chunk(chunk)
      @callbacks_log << :chunk
      @chunks_received << chunk
    end

    def on_close(chunk)
      @callbacks_log << :close
    end
  end

  setup do
    @prompt = TestAgent.new
  end

  # Class method tests
  test "defines callback registration methods" do
    assert_respond_to TestAgent, :on_stream_open
    assert_respond_to TestAgent, :on_stream
    assert_respond_to TestAgent, :on_stream_close
  end

  # StreamChunk tests
  test "StreamChunk stores message and delta" do
    chunk = ActiveAgent::Streaming::StreamChunk.new("test_message", "test_delta")

    assert_equal "test_message", chunk.message
    assert_equal "test_delta", chunk.delta
  end

  # stream_broadcaster tests
  test "stream_broadcaster returns a proc" do
    runner = @prompt.send(:stream_broadcaster)

    assert_instance_of Proc, runner
  end

  test "stream_broadcaster executes open callbacks with type :open" do
    runner = @prompt.send(:stream_broadcaster)

    runner.call("message", "delta", :open)

    assert_includes @prompt.callbacks_log, :open
  end

  test "stream_broadcaster executes stream callbacks on all types" do
    runner = @prompt.send(:stream_broadcaster)

    runner.call("message", "delta", :open)
    runner.call("message", "delta", :update)
    runner.call("message", "delta", :close)

    assert_equal 3, @prompt.callbacks_log.count(:chunk)
  end

  test "stream_broadcaster executes close callbacks with type :close" do
    runner = @prompt.send(:stream_broadcaster)

    runner.call("message", "delta", :close)

    assert_includes @prompt.callbacks_log, :close
  end

  test "stream_broadcaster creates StreamChunk with message and delta" do
    runner = @prompt.send(:stream_broadcaster)

    runner.call("test_msg", "test_delta", :open)

    chunk = @prompt.chunks_received.first
    assert_equal "test_msg", chunk.message
    assert_equal "test_delta", chunk.delta
  end

  test "stream_broadcaster executes callbacks in correct order for full stream" do
    runner = @prompt.send(:stream_broadcaster)

    runner.call("msg", "delta1", :open)
    runner.call("msg", "delta2", :update)
    runner.call("msg", "delta3", :update)
    runner.call("msg", "delta4", :close)

    assert_equal [ :open, :chunk, :chunk, :chunk, :chunk, :close ], @prompt.callbacks_log
  end

  # Callback registration with methods
  test "on_stream_open registers method callbacks" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :called

      on_stream_open :handle_open

      def handle_open(chunk)
        @called = true
      end
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :open)

    assert instance.called
  end

  test "on_stream registers method callbacks" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :called

      on_stream :handle_chunk

      def handle_chunk(chunk)
        @called = true
      end
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :update)

    assert instance.called
  end

  test "on_stream_close registers method callbacks" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :called

      on_stream_close :handle_close

      def handle_close(chunk)
        @called = true
      end
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :close)

    assert instance.called
  end

  # Callback registration with blocks
  test "on_stream_open registers block callbacks" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :called

      on_stream_open { @called = true }
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :open)

    assert instance.called
  end

  test "on_stream registers block callbacks" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :called

      on_stream { @called = true }
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :update)

    assert instance.called
  end

  test "on_stream_close registers block callbacks" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :called

      on_stream_close { @called = true }
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :close)

    assert instance.called
  end

  # Multiple callbacks
  test "executes multiple callbacks in registration order" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :order

      def initialize
        @order = []
      end

      on_stream :first, :second, :third

      def first(chunk)
        @order << :first
      end

      def second(chunk)
        @order << :second
      end

      def third(chunk)
        @order << :third
      end
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :update)

    assert_equal [ :first, :second, :third ], instance.order
  end

  # Callback parameters
  test "callbacks receive StreamChunk as parameter" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :received_chunk

      on_stream :capture

      def capture(chunk)
        @received_chunk = chunk
      end
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("test_msg", "test_delta", :update)

    assert_not_nil instance.received_chunk
    assert_equal "test_msg", instance.received_chunk.message
    assert_equal "test_delta", instance.received_chunk.delta
  end

  # Callback conditions
  test "supports conditional callbacks with :if option" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :called, :condition

      on_stream :conditional_callback, if: :condition

      def conditional_callback(chunk)
        @called = true
      end
    end

    instance = klass.new

    instance.condition = false
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :update)
    refute instance.called

    instance.condition = true
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :update)
    assert instance.called
  end

  test "supports conditional callbacks with :unless option" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :called, :skip_condition

      on_stream :conditional_callback, unless: :skip_condition

      def conditional_callback(chunk)
        @called = true
      end
    end

    instance = klass.new

    instance.skip_condition = true
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :update)
    refute instance.called

    instance.skip_condition = false
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :update)
    assert instance.called
  end

  # Integration test
  test "full streaming lifecycle with all callback types" do
    runner = @prompt.send(:stream_broadcaster)

    # Simulate a complete stream
    runner.call("msg1", "Hello", :open)
    runner.call("msg2", " world", :update)
    runner.call("msg3", "!", :close)

    # Verify callbacks were executed in order
    assert_equal [ :open, :chunk, :chunk, :chunk, :close ], @prompt.callbacks_log

    # Verify all chunks were received
    assert_equal 3, @prompt.chunks_received.size
    assert_equal "Hello", @prompt.chunks_received[0].delta
    assert_equal " world", @prompt.chunks_received[1].delta
    assert_equal "!", @prompt.chunks_received[2].delta
  end

  # Arity detection tests
  test "callbacks with zero arity are called without chunk parameter" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :called

      on_stream :no_params_callback

      def no_params_callback
        @called = true
      end
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :update)

    assert instance.called
  end

  test "callbacks with arity 1 receive chunk parameter" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :received_chunk

      on_stream :with_params_callback

      def with_params_callback(chunk)
        @received_chunk = chunk
      end
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("test_msg", "test_delta", :update)

    assert_not_nil instance.received_chunk
    assert_equal "test_msg", instance.received_chunk.message
    assert_equal "test_delta", instance.received_chunk.delta
  end

  test "supports mixing zero-arity and single-arity callbacks" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :zero_arity_called, :single_arity_chunk

      on_stream :zero_arity_method, :single_arity_method

      def zero_arity_method
        @zero_arity_called = true
      end

      def single_arity_method(chunk)
        @single_arity_chunk = chunk
      end
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :update)

    assert instance.zero_arity_called
    assert_not_nil instance.single_arity_chunk
    assert_equal "delta", instance.single_arity_chunk.delta
  end

  test "on_stream_open respects arity for zero-arity methods" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :called

      on_stream_open :no_params

      def no_params
        @called = true
      end
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :open)

    assert instance.called
  end

  test "on_stream_close respects arity for zero-arity methods" do
    klass = Class.new do
      include ActiveAgent::Streaming
      attr_accessor :called

      on_stream_close :no_params

      def no_params
        @called = true
      end
    end

    instance = klass.new
    runner = instance.send(:stream_broadcaster)
    runner.call("msg", "delta", :close)

    assert instance.called
  end
end
