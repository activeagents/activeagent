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
        class Rails
          class Logger
            def self.info(...); end
          end

          def self.logger
            Logger
          end
        end

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

      class RateLimiting < ActiveSupport::TestCase
        class RateLimiter
          def self.exceeded?(user_id)
            false
          end

          def self.increment(user_id)
            # Increment rate limit counter
          end
        end

        test "rate limiting with generation callbacks" do
          # region rate_limiting
          class RateLimitedAgent < ApplicationAgent
            before_generation :check_rate_limit
            after_generation :record_usage

            def chat
              prompt(message: params[:message])
            end

            private

            def check_rate_limit
              if RateLimiter.exceeded?(params[:user_id])
                throw :abort
              end
            end

            def record_usage
              RateLimiter.increment(params[:user_id])
            end
          end
          # endregion rate_limiting

          response = RateLimitedAgent.with(message: "Hello", user_id: 1).chat.generate_now

          assert_not_nil response
          assert_not_nil response.message.content
        end
      end

      class PromptingCallbacks < ActiveSupport::TestCase
        class Rails
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

        test "prompting callbacks" do
          # region prompting_callbacks
          class MyAgent < ApplicationAgent
            before_prompt :load_context
            after_prompt :cache_response
            around_prompt :measure_time

            def chat
              prompt(message: params[:message])
            end

            private

            def load_context
              @user_data = User.find(params[:user_id])
            end

            def cache_response
              Rails.cache.write("response_#{params[:id]}", "cached")
            end

            def measure_time
              start = Time.current
              yield
              Rails.logger.info "Prompt took #{Time.current - start}s"
            end
          end
          # endregion prompting_callbacks

          response = MyAgent.with(message: "Hello", user_id: 1, id: 123).chat.generate_now

          assert_not_nil response
          assert_not_nil response.message.content
        end
      end

      class EmbeddingCallbacksExample < ActiveSupport::TestCase
        class Rails
          class Logger
            def self.info(...); end
          end

          def self.logger
            Logger
          end
        end

        class VectorDatabase
          def self.store(...); end
        end

        test "embedding callbacks detailed" do
          # region embedding_callbacks_detailed
          class MyAgent < ApplicationAgent
            before_embed :validate_input
            after_embed :store_embedding
            around_embed :measure_time

            def process_text
              embed(input: params[:text])
            end

            private

            def validate_input
              raise "Input too long" if params[:text].length > 8000
            end

            def store_embedding
              VectorDatabase.store(params[:text])
            end

            def measure_time
              start = Time.current
              yield
              Rails.logger.info "Embedding took #{Time.current - start}s"
            end
          end
          # endregion embedding_callbacks_detailed

          response = MyAgent.with(text: "Hello world").process_text.embed_now

          assert_not_nil response
          assert_not_nil response.data
        end
      end

      class CallbackControl < ActiveSupport::TestCase
        test "callback control methods" do
          # region callback_control
          class BaseAgent < ApplicationAgent
            before_generation :base_setup
            after_prompt :log_response

            def chat
              prompt(message: params[:message])
            end

            private

            def base_setup
              # Base setup logic
            end

            def log_response
              # Log response
            end
          end

          class ChildAgent < BaseAgent
            prepend_before_generation :critical_auth  # Runs before inherited callbacks
            skip_after_prompt :log_response           # Remove inherited callback
            append_before_prompt :final_setup         # Same as before_prompt

            private

            def critical_auth
              # Critical authentication logic
            end

            def final_setup
              # Final setup logic
            end
          end
          # endregion callback_control

          response = ChildAgent.with(message: "Hello").chat.generate_now

          assert_not_nil response
          assert_not_nil response.message.content
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
