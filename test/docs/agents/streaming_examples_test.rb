require "test_helper"

module Docs
  module Agents
    module StreamingExamples
      class Basic < ActiveSupport::TestCase
        # region basic_streaming_agent
        class ChatAgent < ActiveAgent::Base
          generate_with :openai, model: "gpt-4", stream: true

          on_stream :handle_chunk

          def chat(message)
            prompt(message)
          end

          private

          def handle_chunk(chunk)
            print chunk.delta if chunk.delta
          end
        end
        # endregion basic_streaming_agent
        test "Basic Example" do
          response = nil
          VCR.use_cassette("docs/agents/streaming_examples/basic_streaming") do
            response =
            # region basic_streaming_usage
            # Usage
            ChatAgent.chat("Hello!").generate_now
            # endregion basic_streaming_usage
          end

          assert response.message.content.present?
        end
      end

      class Lifecycle < ActiveSupport::TestCase
        class Message
          def self.create!(...); end
        end

        class Server
          def self.broadcast(...); end
        end

        test "Lifecycle Example" do
          ActionCable.stub(:server, Server) do
            class StreamingAgent < ActiveAgent::Base
              generate_with :anthropic, model: "claude-haiku-4-5"

              # region lifecycle_open
              on_stream_open :start_timer

              def start_timer(chunk)
                @start_time = Time.current
              end
              # endregion lifecycle_open

              # region lifecycle_chunk
              on_stream :broadcast_chunk

              def broadcast_chunk(chunk)
                return unless chunk.delta

                ActionCable.server.broadcast("chat", content: chunk.delta)
              end
              # endregion lifecycle_chunk

              # region lifecycle_close
              on_stream_close :save_response

              def save_response(chunk)
                Message.create!(content: chunk.message)
              end
              # endregion lifecycle_close

              def generate_content(text)
                prompt(text, stream: true)
              end
            end

            VCR.use_cassette("docs/agents/streaming_examples/lifecycle") do
              response = StreamingAgent.generate_content("Hello!").generate_now

              assert response.message.content.present?
            end
          end
        end
      end

      class Callback < ActiveSupport::TestCase
        class Rails
          class ENV
            def self.development? = true
          end

          def self.env = ENV

          class Logger
            def self.info(...); end
          end
          def self.logger
            Logger
          end
        end

        test "Callback Parameters Optional" do
          class OptionalAgent < ActiveAgent::Base
            generate_with :openai, model: "gpt-4", stream: true

            # region callbacks_parameters_optional
            # With chunk parameter - receives StreamChunk
            on_stream :process_chunk

            def process_chunk(chunk)
              print chunk.delta if chunk.delta
            end

            # Without chunk parameter
            on_stream :increment_counter

            def increment_counter
              @counter ||= 0
              @counter += 1
            end
            # endregion callbacks_parameters_optional

            def generate_content(text)
              prompt(text, stream: true)
            end
          end

          VCR.use_cassette("docs/agents/streaming_examples/callbacks_parameters_optional") do
            response = OptionalAgent.generate_content("Hello!").generate_now

            assert response.message.content.present?
          end
        end

        test "Callback Parameters Multiple" do
          class ConditionalAgent < ActiveAgent::Base
            generate_with :openai, model: "gpt-4", stream: true

            # region callbacks_parameters_multiple
            on_stream :log_chunk, :broadcast_chunk, :save_to_buffer
            # endregion callbacks_parameters_multiple

            def log_chunk; end
            def broadcast_chunk; end
            def save_to_buffer; end

            def generate_content(text)
              prompt(text, stream: true)
            end
          end

          VCR.use_cassette("docs/agents/streaming_examples/callbacks_parameters_multiple") do
            response = ConditionalAgent.generate_content("Hello!").generate_now

            assert response.message.content.present?
          end
        end

        test "Callback Parameters Conditional" do
          class ConditionalAgent < ActiveAgent::Base
            generate_with :openai, model: "gpt-4", stream: true

            # region callbacks_parameters_conditional
            on_stream       :debug_chunk,   if:     :debug_mode?
            on_stream_close :save_response, unless: :test_environment?

            def debug_mode?
              Rails.env.development?
            end
            # endregion callbacks_parameters_conditional

            def debug_chunk; end
            def save_response; end
            def test_environment?
              false
            end

            def generate_content(text)
              prompt(text, stream: true)
            end
          end

          VCR.use_cassette("docs/agents/streaming_examples/callbacks_parameters_conditional") do
            response = ConditionalAgent.generate_content("Hello!").generate_now

            assert response.message.content.present?
          end
        end

        test "Callback Parameters Blocks" do
          class BlocksAgent < ActiveAgent::Base
            generate_with :openai, model: "gpt-4", stream: true

            # region callbacks_paramters_blocks
            on_stream do |chunk|
              print chunk.delta if chunk.delta
            end

            on_stream_close do
              Rails.logger.info("Stream completed")
            end
            # endregion callbacks_paramters_blocks

            def generate_content(text)
              prompt(text, stream: true)
            end
          end

          VCR.use_cassette("docs/agents/streaming_examples/callbacks_paramters_blocks") do
            response = BlocksAgent.generate_content("Hello!").generate_now

            assert response.message.content.present?
          end
        end
      end
    end
  end
end
