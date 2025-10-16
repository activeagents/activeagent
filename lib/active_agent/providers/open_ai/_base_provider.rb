require_relative "../_base_provider"

require_gem!(:openai, __FILE__)

require_relative "options"

module ActiveAgent
  module Providers
    module OpenAI
      class BaseProvider < ActiveAgent::Providers::BaseProvider
        attr_internal :stream_callback, :function_callback

        def initialize(kwargs = {})
          self.stream_callback   = kwargs.delete(:stream_callback)
          self.function_callback = kwargs.delete(:function_callback)

          super(kwargs)
        end

        # @return [OpenAI::Client]
        def client
          ::OpenAI::Client.new(options.to_hc)
        end

        def call
          with_error_handling do
            resolve_prompt
          end
        end

        # @return [String] Name of service, e.g., Anthropic
        def service_name = "OpenAI"

        protected

        # @return [Class] The Options class for the specific provider, e.g., Anthropic::Options
        def options_type = OpenAI::Options

        def process_stream
          proc do |api_response_chunk|
            process_stream_chunk(api_response_chunk.deep_symbolize_keys)
          end
        end
      end
    end
  end
end
