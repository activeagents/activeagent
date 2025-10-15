require_relative "../_base_provider"

require_gem!(:openai, __FILE__)

require_relative "options"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      class BaseProvider < ActiveAgent::GenerationProvider::BaseProvider
        include MessageFormatting
        include ToolManagement

        # @return [OpenAI::Client]
        def client
          ::OpenAI::Client.new(options.client_options)
        end

        def generate(prompt_context)
          with_error_handling do
            generate_prompt(prompt_context)
          end
        end

        # @return [String] Name of service, e.g., Anthropic
        def service_name = "OpenAI"

        protected

        # @return [Class] The Options class for the specific provider, e.g., Anthropic::Options
        def options_type = OpenAI::Options
      end
    end
  end
end
