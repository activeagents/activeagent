module ActiveAgent
  module GenerationProvider
    class OpenAIProvider < Base
      class BaseAdapter
        def initialize(prompt, config, model)
          @prompt = prompt
          @config = config
          @model = model
        end

        protected

        def has_structured_output?(params = nil)
          params ||= @prompt&.options || {}
          params[:json_schema].present? || 
          @config&.dig("json_schema").present?
        end

        def parse_structured_content(content)
          return content unless content.is_a?(String)
          return content unless has_structured_output?
          
          # Try to parse as JSON if it looks like JSON and structured output is enabled
          if content.strip.start_with?('{', '[')
            begin
              parsed = JSON.parse(content)
              # Convert string keys to symbols if it's a hash
              if parsed.is_a?(Hash)
                parsed.deep_symbolize_keys
              else
                parsed
              end
            rescue JSON::ParserError
              content
            end
          else
            content
          end
        end
      end
    end
  end
end