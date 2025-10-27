require "test_helper"

module Docs
  module Agents
    module CallbacksExamples
      # Test agent using Mock provider to avoid VCR dependencies
      class ApplicationAgent < ActiveAgent::Base
        generate_with :mock
        embed_with :mock
      end

      class User
        def self.find(...); new; end
      end

      class VectorDB
        def self.store(...); end
      end

      class BeforeGeneration < ActiveSupport::TestCase
        test "before generation callback" do
          # region before_generation
          class MyAgent < ApplicationAgent
            before_generation :load_context

            def chat
              prompt(message: params[:message])
            end

            private

            def load_context
              @user_data = User.find(params[:user_id])
            end
          end
          # endregion before_generation

          response = MyAgent.with(message: "Hello", user_id: 1).chat.generate_now

          assert_not_nil response
          assert_not_nil response.message.content
        end
      end

      class AfterGeneration < ActiveSupport::TestCase
        class Rails
          class Logger
            def self.info(...); end
          end

          def self.logger
            Logger
          end
        end

        test "after generation callback" do
          # region after_generation
          class LoggingAgent < ApplicationAgent
            after_generation :log_completion

            def chat
              prompt(message: params[:message])
            end

            private

            def log_completion
              Rails.logger.info "Completed generation"
            end
          end
          # endregion after_generation

          response = LoggingAgent.with(message: "Hello").chat.generate_now

          assert_not_nil response
          assert_not_nil response.message.content
        end
      end

      class AroundGeneration < ActiveSupport::TestCase
        class Rails
          class Logger
            def self.info(...); end
          end

          def self.logger
            Logger
          end
        end

        test "around generation callback" do
          # region around_generation
          class TimingAgent < ApplicationAgent
            around_generation :measure_time

            def chat
              prompt(message: params[:message])
            end

            private

            def measure_time
              start = Time.current
              yield
              duration = Time.current - start
              Rails.logger.info "Generation took #{duration}s"
            end
          end
          # endregion around_generation

          response = TimingAgent.with(message: "Hello").chat.generate_now

          assert_not_nil response
          assert_not_nil response.message.content
        end
      end

      class MultipleConditionalCallbacks < ActiveSupport::TestCase
        class Rails
          class ENV
            def self.production? = true
            def self.test? = false
          end

          def self.env = ENV

          class Logger
            def self.info(...); end
          end

          def self.logger
            Logger
          end

          class Cache
            def self.write(...); end
          end

          def self.cache
            Cache
          end
        end

        test "multiple and conditional callbacks" do
          # region multiple_conditional_callbacks
          class AdvancedAgent < ApplicationAgent
            before_generation :load_context
            before_generation :check_rate_limit, if: :rate_limiting_enabled?
            after_generation :log_response

            def chat
              prompt(message: params[:message])
            end

            private

            def load_context
              @user_data = User.find(params[:user_id])
            end

            def check_rate_limit
              raise "Rate limit exceeded" if rate_limited?
            end

            def log_response
              Rails.logger.info "Completed generation"
            end

            def rate_limiting_enabled?
              Rails.env.production?
            end

            def test_environment?
              Rails.env.test?
            end

            def rate_limited?
              false
            end
          end
          # endregion multiple_conditional_callbacks

          response = AdvancedAgent.with(message: "Hello", user_id: 1).chat.generate_now

          assert_not_nil response
          assert_not_nil response.message.content
        end
      end

      class EmbeddingCallbacks < ActiveSupport::TestCase
        test "embedding callbacks" do
          # region embedding_callbacks
          class EmbeddingAgent < ApplicationAgent
            before_embed :validate_input
            around_embed :measure_time

            def process_text
              embed(input: params[:text])
            end

            private

            def validate_input
              raise "Text too long" if params[:text].length > 10_000
            end

            def measure_time
              start = Time.current
              yield
              Rails.logger.info "Embedding took #{Time.current - start}s"
            end
          end
          # endregion embedding_callbacks

          response = EmbeddingAgent.with(text: "Hello world").process_text.embed_now

          assert_not_nil response
          assert_not_nil response.data
        end
      end

      class StreamingCallbacks < ActiveSupport::TestCase
        class Rails
          class Logger
            def self.info(...); end
          end

          def self.logger
            Logger
          end
        end

        test "streaming callbacks" do
          # region streaming_callbacks
          class StreamingAgent < ApplicationAgent
            on_stream_open :initialize_stream
            on_stream :process_chunk
            on_stream_close :finalize_stream

            def chat
              prompt(message: params[:message], stream: true)
            end

            private

            def initialize_stream
              @start_time = Time.current
              @chunk_count = 0
            end

            def process_chunk(chunk)
              @chunk_count += 1
              # Process each chunk as it arrives
              broadcast_chunk(chunk)
            end

            def finalize_stream
              duration = Time.current - @start_time
              Rails.logger.info "Streamed #{@chunk_count} chunks in #{duration}s"
            end

            def broadcast_chunk(chunk)
              # Broadcast implementation
            end
          end
          # endregion streaming_callbacks

          response = StreamingAgent.with(message: "Hello").chat.generate_now

          assert_not_nil response
          assert_not_nil response.message.content
        end
      end
    end
  end
end
