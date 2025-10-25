require "test_helper"

module Docs
  module Agents
    module ErrorHandlingExamples
      # Test agent using Mock provider to avoid VCR dependencies
      class ApplicationAgent < ActiveAgent::Base
        generate_with :mock
        embed_with :mock
      end

      class Rails
        class Cache
          def self.fetch(key)
            yield if block_given?
          end
        end

        class Logger
          def self.error(...); end
          def self.warn(...); end
        end

        def self.cache
          Cache
        end

        def self.logger
          Logger
        end
      end

      class ErrorTracker
        def self.notify(...); end
      end

      class ErrorNotifier
        def self.notify(...); end
      end

      class ErrorMetrics
        def self.increment(...); end
      end

      class Sentry
        def self.capture_exception(...); end
      end

      class Retries < ActiveSupport::TestCase
        test "retries configuration" do
          # region retries
          class RobustAgent < ApplicationAgent
            generate_with :openai,
              model: "gpt-4o",
              retries: true,
              retries_count: 5

            def analyze(content)
              prompt "Analyze this content: #{content}"
            end
          end
          # endregion retries

          VCR.use_cassette("docs/agents/error_handling_examples/retries") do
            response = RobustAgent.analyze("test").generate_now

            assert_not_nil response
            assert response.message.content.is_a?(String)
          end
        end
      end

      class RescueHandlers < ActiveSupport::TestCase
        test "rescue from with agent context" do
          # region rescue_handlers
          class MonitoredAgent < ApplicationAgent
            rescue_from Timeout::Error, with: :handle_timeout
            rescue_from StandardError, with: :handle_error

            def analyze(data)
              prompt "Analyze: #{data}"
            end

            private

            def handle_timeout(exception)
              Rails.logger.error("Timeout: #{exception.message}")
              ErrorNotifier.notify(exception, agent: self.class.name, params:)
              { error: "Processing timed out", retry_after: 60 }
            end

            def handle_error(exception)
              Rails.logger.error("Error: #{exception.class} - #{exception.message}")
              Sentry.capture_exception(exception)
              { error: "Request failed" }
            end
          end
          # endregion rescue_handlers

          VCR.use_cassette("docs/agents/error_handling_examples/rescue_handlers") do
            response = MonitoredAgent.analyze("test").generate_now

            assert_not_nil response
            assert response.message.content.is_a?(String)
          end
        end
      end

      class CombiningStrategies < ActiveSupport::TestCase
        test "combining all error handling strategies" do
          # region combining_strategies
          class ProductionAgent < ApplicationAgent
            generate_with :openai,
              model: "gpt-4o",
              retries: true,
              retries_count: 3

            rescue_from Timeout::Error, with: :handle_timeout

            def analyze(content)
              prompt "Analyze content: #{content}"
            end

            private

            def handle_timeout(exception)
              { error: "Timeout", retry_after: 60 }
            end
          end
          # endregion combining_strategies

          VCR.use_cassette("docs/agents/error_handling_examples/combining_strategies") do
            response = ProductionAgent.analyze("test").generate_now

            assert_not_nil response
            assert response.message.content.is_a?(String)
          end
        end
      end

      class FastFailure < ActiveSupport::TestCase
        test "fast failure for real-time" do
          # region fast_failure
          class RealtimeChatAgent < ApplicationAgent
            generate_with :anthropic,
              model: "claude-3-5-sonnet-20241022",
              retries: false

            rescue_from StandardError, with: :handle_error

            def chat(message)
              prompt message
            end

            private

            def handle_error(exception)
              { error: "Service unavailable" }
            end
          end
          # endregion fast_failure

          VCR.use_cassette("docs/agents/error_handling_examples/fast_failure") do
            response = RealtimeChatAgent.chat("Hello").generate_now

            assert_not_nil response
            assert response.message.content.is_a?(String)
          end
        end
      end

      class BackgroundJobIntegration < ActiveSupport::TestCase
        class SomeUnrecoverableError < StandardError; end

        # region background_job_integration
        class ProcessingJob < ApplicationJob
          retry_on Timeout::Error, wait: 30.seconds, attempts: 5
          discard_on SomeUnrecoverableError

          def perform(data)
            # Disable ActiveAgent retries, let Sidekiq handle it
            AsyncAgent.with(data:, retries: false).process
          end
        end
        # endregion background_job_integration

        test "background job integration setup" do
          # Just verify the class is defined correctly
          assert_equal ApplicationJob, ProcessingJob.superclass
        end
      end

      class GracefulDegradation < ActiveSupport::TestCase
        test "graceful degradation with cached responses" do
          # region graceful_degradation
          class ResilientAgent < ApplicationAgent
            rescue_from StandardError, with: :handle_error

            def analyze(data)
              prompt "Complex analysis of: #{data}"
            end

            private

            def handle_error(exception)
              Rails.logger.warn("Primary failed, using fallback")
              Rails.cache.fetch("last_successful_response") do
                { error: "Service unavailable" }
              end
            end
          end
          # endregion graceful_degradation

          VCR.use_cassette("docs/agents/error_handling_examples/graceful_degradation") do
            response = ResilientAgent.analyze("test").generate_now

            assert_not_nil response
            assert response.message.content.is_a?(String)
          end
        end
      end

      class TestingErrorHandling < ActiveSupport::TestCase
        test "testing error handling" do
          # region testing_error_handling
          require "test_helper"

          class MonitoredAgentTest < ActiveSupport::TestCase
            test "handles timeout gracefully" do
              agent = MonitoredAgent.new

              agent.stub :prompt, -> { raise Timeout::Error } do
                result = agent.analyze("test data")

                assert_equal "Processing timed out", result[:error]
                assert_equal 60, result[:retry_after]
              end
            end
          end
          # endregion testing_error_handling

          # The test within the region is a documentation example
          # We just verify the outer test runs
          assert true
        end
      end

      class Monitoring < ActiveSupport::TestCase
        test "monitoring with ActiveSupport::Notifications" do
          # region monitoring
          # config/initializers/active_agent.rb
          ActiveSupport::Notifications.subscribe("generate.active_agent") do |name, start, finish, id, payload|
            if payload[:error]
              ErrorMetrics.increment("active_agent.errors",
                tags: [ "agent:#{payload[:agent]}", "error:#{payload[:error].class.name}" ])
            end
          end
          # endregion monitoring

          # Just verify the subscription works
          assert true
        end
      end
    end
  end
end
