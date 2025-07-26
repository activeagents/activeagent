require_relative "base_adapter"

module ActiveAgent
  module GenerationProvider
    class ResponsesAdapter < BaseAdapter
      def initialize(prompt)
        super(prompt)
        @prompt = prompt
      end

      def input
          messages.map do |message|
          if message.content.is_a?(Array)
            {
              role: message.role,
              content: message.content.map do |content_part|
                if content_part.is_a?(String)
                  { type: "input_text", text: content_part }
                elsif content_part.is_a?(ActiveAgent::ActionPrompt::Message) && content_part.content_type == "input_text"
                  { type: "input_text", text: content_part.content }
                elsif content_part.is_a?(ActiveAgent::ActionPrompt::Message) && content_part.content_type == "image_data"
                  { type: "input_image", image_url: content_part.content }
                elsif content_part.is_a?(ActiveAgent::ActionPrompt::Message) && content_part.content_type == "file_data"
                  { type: "input_file", filename: content_part.metadata[:filename], file_data: content_part.content }
                else
                  raise ArgumentError, "Unsupported content type in message"
                end
              end.compact
            }
          else
            {
              role: message.role,
              content: message.content
            }
          end
        end.compact
      end

      def messages
        prompt.messages
      end
    end
  end
end
