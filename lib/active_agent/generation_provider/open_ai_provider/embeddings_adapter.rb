require_relative "base_adapter"

module ActiveAgent
  module GenerationProvider
    class OpenAIProvider < Base
      class EmbeddingsAdapter < BaseAdapter
        def parameters(input: nil, model: nil)
          # Use provided arguments or fall back to instance variables
          input_text = input || format_input(@prompt.messages)
          model_name = model || @model || "text-embedding-ada-002"
          
          params = {
            input: input_text,
            model: model_name
          }.compact

          # Add additional options if present in prompt options or config
          params[:encoding_format] = @prompt.options[:encoding_format] || @config["encoding_format"] if @prompt.options[:encoding_format] || @config["encoding_format"]
          params[:dimensions] = @prompt.options[:dimensions] || @config["dimensions"] if @prompt.options[:dimensions] || @config["dimensions"]
          params[:user] = @prompt.options[:user] || @config["user"] if @prompt.options[:user] || @config["user"]

          params
        end

        def parse_response(response)
          # Extract the embedding vector from the response
          embedding_data = response.dig("data", 0)
          return nil unless embedding_data

          # Return a Message with the embedding array as content
          ActiveAgent::ActionPrompt::Message.new(
            content: embedding_data["embedding"],
            role: "assistant"
          )
        end

        private

        def format_input(messages)
          case messages
          when Array
            if messages.length == 1 && messages.first.respond_to?(:content)
              # Single message, extract content as string
              messages.first.content.to_s
            else
              # Multiple messages, join them or take first
              messages.map { |msg| 
                if msg.respond_to?(:content)
                  msg.content.to_s
                else
                  msg.to_s
                end
              }.join(" ")
            end
          when String
            messages
          else
            messages.to_s
          end
        end
      end
    end
  end
end