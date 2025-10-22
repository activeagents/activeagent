# frozen_string_literal: true

require_relative "_base_provider"
require_relative "mock/_types"

module ActiveAgent
  module Providers
    # Mock provider for testing purposes.
    #
    # This provider doesn't make real API calls. Instead, it returns the last
    # message content converted to pig latin for prompts, and random data for embeddings.
    # Useful for testing without incurring API costs or requiring network access.
    #
    # @example Basic usage
    #   provider = ActiveAgent::Providers::MockProvider.new(...)
    #   result = provider.prompt
    #
    # @see BaseProvider
    class MockProvider < BaseProvider
      # Returns a mock client (just returns self since we don't need a real client).
      #
      # @return [MockProvider] Returns self
      def client
        self
      end

      # Returns the embedding request type for Mock.
      #
      # @return [ActiveModel::Type::Value] The Mock embedding request type
      def embed_request_type
        Mock::EmbeddingRequestType.new
      end

      protected

      # Executes a mock prompt request.
      #
      # Extracts the last user message, converts it to pig latin, and returns
      # a mock response structure. Handles both streaming and non-streaming.
      #
      # @param parameters [Hash] The prompt request parameters
      # @return [Hash] A mock API response structure
      def api_prompt_execute(parameters)
        # Extract the last message content
        last_message = parameters[:messages]&.last
        content = extract_message_content(last_message)

        # Convert to pig latin
        pig_latin_content = to_pig_latin(content)

        if parameters[:stream]
          # For streaming, call the stream proc with chunks
          stream_proc = parameters[:stream]
          simulate_streaming(pig_latin_content, stream_proc)
          nil
        else
          # Return a complete response
          {
            id: "mock-#{SecureRandom.hex(8)}",
            type: "message",
            role: "assistant",
            content: [
              {
                type: "text",
                text: pig_latin_content
              }
            ],
            model: parameters[:model] || "mock-model",
            stop_reason: "end_turn",
            usage: {
              input_tokens: content.length,
              output_tokens: pig_latin_content.length
            }
          }
        end
      end

      # Executes a mock embedding request.
      #
      # Returns random embedding vectors for testing purposes.
      #
      # @param parameters [Hash] The embedding request parameters
      # @return [Hash] A mock embedding response structure
      def api_embed_execute(parameters)
        input = parameters[:input]
        inputs = input.is_a?(Array) ? input : [ input ]
        dimensions = parameters[:dimensions] || 1536

        {
          object: "list",
          data: inputs.map.with_index do |text, index|
            {
              object: "embedding",
              index: index,
              embedding: generate_random_embedding(dimensions)
            }
          end,
          model: parameters[:model] || "mock-embedding-model",
          usage: {
            prompt_tokens: inputs.sum { |text| text.to_s.length },
            total_tokens: inputs.sum { |text| text.to_s.length }
          }
        }
      end

      # Processes streaming response chunks.
      #
      # Handles mock streaming chunks, similar to real provider implementations.
      #
      # @param api_response_chunk [Hash] The streaming response chunk
      # @return [void]
      def process_stream_chunk(api_response_chunk)
        chunk_type = api_response_chunk[:type]&.to_sym

        instrument("stream_chunk_processing.provider.active_agent", chunk_type: chunk_type)

        broadcast_stream_open

        case chunk_type
        when :message_start
          api_message = api_response_chunk[:message]
          message_stack.push(api_message)
          broadcast_stream_update(message_stack.last)

        when :content_block_start
          api_content = api_response_chunk[:content_block]
          message_stack.last[:content] ||= []
          message_stack.last[:content].push(api_content)
          broadcast_stream_update(message_stack.last, api_content[:text])

        when :content_block_delta
          index = api_response_chunk[:index]
          content = message_stack.last[:content][index]
          delta = api_response_chunk[:delta]

          if delta[:type] == "text_delta"
            content[:text] ||= ""
            content[:text] += delta[:text]
            broadcast_stream_update(message_stack.last, delta[:text])
          end

        when :message_delta
          delta = api_response_chunk[:delta]
          message_stack.last[:stop_reason] = delta[:stop_reason] if delta[:stop_reason]

        when :message_stop
          # Stream complete
        end
      end

      # Extracts messages from API response.
      #
      # @param api_response [Hash] The API response
      # @return [Array<Hash>] Array of message hashes
      def process_prompt_finished_extract_messages(api_response)
        return nil if api_response.nil? # Streaming case
        [ api_response ]
      end

      # Extracts function calls from API response.
      #
      # Mock provider doesn't support tool calling by default.
      #
      # @return [nil]
      def process_prompt_finished_extract_function_calls
        nil
      end

      private

      # Extracts text content from a message.
      #
      # @param message [Hash, String, nil] The message to extract from
      # @return [String] The extracted text content
      def extract_message_content(message)
        return "" if message.nil?

        case message
        when String
          message
        when Hash
          if message[:content].is_a?(String)
            message[:content]
          elsif message[:content].is_a?(Array)
            message[:content]
              .select { |block| block.is_a?(Hash) && block[:type] == "text" }
              .map { |block| block[:text] }
              .join(" ")
          else
            message[:content].to_s
          end
        else
          message.to_s
        end
      end

      # Converts text to pig latin.
      #
      # Simple pig latin conversion:
      # - Words starting with vowels: add "way" to the end
      # - Words starting with consonants: move consonants to end and add "ay"
      # - Preserves punctuation and capitalization
      #
      # @param text [String] The text to convert
      # @return [String] The text in pig latin
      def to_pig_latin(text)
        return "" if text.nil? || text.empty?

        words = text.split(/\b/)

        words.map do |word|
          # Skip non-word characters (spaces, punctuation, etc.)
          next word unless word.match?(/\w/)

          # Check if word starts with a vowel
          if word.match?(/^[aeiouAEIOU]/)
            "#{word}way"
          else
            # Find the first vowel
            match = word.match(/^([^aeiouAEIOU]+)(.*)/)
            if match
              consonants = match[1]
              rest = match[2]

              # Preserve capitalization
              if word[0] == word[0].upcase && rest.length > 0
                "#{rest[0].upcase}#{rest[1..-1]}#{consonants.downcase}ay"
              else
                "#{rest}#{consonants}ay"
              end
            else
              # No vowels found, just add "ay"
              "#{word}ay"
            end
          end
        end.join
      end

      # Simulates streaming by sending chunks.
      #
      # @param content [String] The full content to stream
      # @param stream_proc [Proc] The streaming callback
      # @return [void]
      def simulate_streaming(content, stream_proc)
        message_id = "mock-#{SecureRandom.hex(8)}"

        # Send message_start
        stream_proc.call({
          type: :message_start,
          message: {
            id: message_id,
            type: "message",
            role: "assistant",
            content: [],
            model: "mock-model"
          }
        })

        # Send content_block_start
        stream_proc.call({
          type: :content_block_start,
          index: 0,
          content_block: {
            type: "text",
            text: ""
          }
        })

        # Send content in chunks (simulate word-by-word streaming)
        words = content.split(" ")
        words.each_with_index do |word, i|
          text_chunk = i == 0 ? word : " #{word}"
          stream_proc.call({
            type: :content_block_delta,
            index: 0,
            delta: {
              type: "text_delta",
              text: text_chunk
            }
          })
        end

        # Send message_delta with stop_reason
        stream_proc.call({
          type: :message_delta,
          delta: {
            stop_reason: "end_turn"
          }
        })

        # Send message_stop
        stream_proc.call({
          type: :message_stop
        })
      end

      # Generates a random embedding vector.
      #
      # @param dimensions [Integer] The number of dimensions for the embedding
      # @return [Array<Float>] A random normalized vector
      def generate_random_embedding(dimensions)
        # Generate random values between -1 and 1
        vector = Array.new(dimensions) { rand * 2 - 1 }

        # Normalize the vector to unit length (common for embeddings)
        magnitude = Math.sqrt(vector.sum { |v| v ** 2 })
        vector.map { |v| v / magnitude }
      end
    end
  end
end
