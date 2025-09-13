# frozen_string_literal: true

require_relative "base"
require_relative "response"
require_relative "stream_processing"
require_relative "message_formatting"
require_relative "tool_management"

module ActiveAgent
  module GenerationProvider
    class TransformersProvider < Base
      include StreamProcessing
      include MessageFormatting
      include ToolManagement

      attr_reader :model, :tokenizer, :pipeline

      def initialize(config)
        super(config)
        @config = config
        @model_type = config["model_type"] || "generation" # generation, embedding, sentiment, etc.
        @model_name = config["model"] || config["model_name"]
        @task = config["task"] || infer_task_from_model_type

        setup_model
      end

      def generate(prompt)
        @prompt = prompt

        case @model_type
        when "generation", "text-generation"
          generate_text(prompt)
        when "embedding", "feature-extraction"
          generate_embedding(prompt)
        when "sentiment", "sentiment-analysis"
          analyze_sentiment(prompt)
        when "summarization"
          summarize_text(prompt)
        when "translation"
          translate_text(prompt)
        when "question-answering"
          answer_question(prompt)
        else
          # Try to use the pipeline directly
          run_pipeline(prompt)
        end
      end

      def embed(prompt)
        @prompt = prompt
        generate_embedding(prompt)
      end

      private

      def infer_task_from_model_type
        case @model_type
        when "generation"
          "text-generation"
        when "embedding"
          "feature-extraction"
        when "sentiment"
          "sentiment-analysis"
        else
          @model_type
        end
      end

      def setup_model
        require "transformers-ruby" unless defined?(Transformers)

        # Initialize the transformer pipeline
        pipeline_options = {
          task: @task,
          model: @model_name
        }.compact

        # Add device configuration if specified
        if @config["device"]
          pipeline_options[:device] = @config["device"]
        end

        # Create the pipeline
        @pipeline = Transformers.pipeline(**pipeline_options)

        # For advanced usage, also expose model and tokenizer
        if @config["expose_components"]
          setup_components
        end
      rescue LoadError
        raise LoadError, "Please install the 'transformers-ruby' gem: gem install transformers-ruby"
      rescue => e
        raise RuntimeError, "Failed to initialize Transformers model: #{e.message}"
      end

      def setup_components
        # Load model and tokenizer separately for advanced usage
        if @model_name
          @model = Transformers::AutoModel.from_pretrained(@model_name)
          @tokenizer = Transformers::AutoTokenizer.from_pretrained(@model_name)
        end
      end

      def generate_text(prompt)
        input_text = extract_input_text(prompt)

        generation_args = build_generation_args

        result = @pipeline.call(input_text, **generation_args)

        handle_text_response(result, input_text)
      end

      def generate_embedding(prompt)
        input_text = extract_input_text(prompt)

        # Use feature extraction pipeline for embeddings
        if @pipeline && @task == "feature-extraction"
          result = @pipeline.call(input_text)
        elsif @model && @tokenizer
          # Use model directly for embeddings
          inputs = @tokenizer.call(input_text, return_tensors: "pt", padding: true, truncation: true)
          outputs = @model.call(**inputs)
          result = outputs.last_hidden_state.mean(dim: 1).squeeze.to_a
        else
          raise RuntimeError, "Model not configured for embeddings"
        end

        handle_embedding_response(result, input_text)
      end

      def analyze_sentiment(prompt)
        input_text = extract_input_text(prompt)

        result = @pipeline.call(input_text)

        handle_sentiment_response(result, input_text)
      end

      def summarize_text(prompt)
        input_text = extract_input_text(prompt)

        summarization_args = {
          max_length: @config["max_length"] || 150,
          min_length: @config["min_length"] || 30,
          do_sample: @config["do_sample"] || false
        }

        result = @pipeline.call(input_text, **summarization_args)

        handle_text_response(result, input_text)
      end

      def translate_text(prompt)
        input_text = extract_input_text(prompt)

        # Translation typically requires source and target languages
        translation_args = {}
        translation_args[:src_lang] = @config["source_language"] if @config["source_language"]
        translation_args[:tgt_lang] = @config["target_language"] if @config["target_language"]

        result = @pipeline.call(input_text, **translation_args)

        handle_text_response(result, input_text)
      end

      def answer_question(prompt)
        input_data = if prompt.respond_to?(:message)
          # Extract question and context from prompt
          message_content = prompt.message.content
          if message_content.is_a?(Hash)
            {
              question: message_content["question"] || message_content[:question],
              context: message_content["context"] || message_content[:context]
            }
          else
            # Try to parse from string
            parts = message_content.split("\nContext: ")
            if parts.length == 2
              question, context = parts[0].sub("Question: ", ""), parts[1]
              { question: question, context: context }
            else
              { question: message_content, context: "" }
            end
          end
        else
          { question: prompt.to_s, context: "" }
        end

        result = @pipeline.call(**input_data)

        handle_qa_response(result, input_data)
      end

      def run_pipeline(prompt)
        input_text = extract_input_text(prompt)

        # Run the pipeline with default settings
        result = @pipeline.call(input_text)

        handle_generic_response(result, input_text)
      end

      def extract_input_text(prompt)
        if prompt.respond_to?(:message)
          prompt.message.content
        elsif prompt.respond_to?(:messages)
          # For multi-turn conversations, join messages
          prompt.messages.map { |m| "#{m.role}: #{m.content}" }.join("\n")
        elsif prompt.is_a?(String)
          prompt
        else
          prompt.to_s
        end
      end

      def build_generation_args
        args = {}

        # Map configuration to generation arguments
        args[:max_new_tokens] = @config["max_tokens"] if @config["max_tokens"]
        args[:max_length] = @config["max_length"] if @config["max_length"]
        args[:min_length] = @config["min_length"] if @config["min_length"]
        args[:temperature] = @config["temperature"] if @config["temperature"]
        args[:top_p] = @config["top_p"] if @config["top_p"]
        args[:top_k] = @config["top_k"] if @config["top_k"]
        args[:do_sample] = @config["do_sample"] if @config.key?("do_sample")
        args[:num_beams] = @config["num_beams"] if @config["num_beams"]
        args[:repetition_penalty] = @config["repetition_penalty"] if @config["repetition_penalty"]
        args[:length_penalty] = @config["length_penalty"] if @config["length_penalty"]
        args[:early_stopping] = @config["early_stopping"] if @config.key?("early_stopping")
        args[:pad_token_id] = @config["pad_token_id"] if @config["pad_token_id"]
        args[:eos_token_id] = @config["eos_token_id"] if @config["eos_token_id"]
        args[:num_return_sequences] = @config["num_return_sequences"] if @config["num_return_sequences"]

        args
      end

      def handle_text_response(result, input_text)
        # Extract text from result
        content = extract_text_from_result(result)

        message = ActiveAgent::ActionPrompt::Message.new(
          role: "assistant",
          content: content
        )

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: @prompt,
          message: message,
          raw_response: result,
          raw_request: { input: input_text, config: @config }
        )

        update_context(prompt: @prompt, message: message, response: @response)
        @response
      end

      def handle_embedding_response(result, input_text)
        # Normalize embedding format
        embedding_vector = normalize_embedding(result)

        message = ActiveAgent::ActionPrompt::Message.new(
          role: "assistant",
          content: embedding_vector
        )

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: @prompt,
          message: message,
          raw_response: { embedding: embedding_vector },
          raw_request: { input: input_text, config: @config }
        )

        @response
      end

      def handle_sentiment_response(result, input_text)
        # Format sentiment analysis result
        sentiment_data = if result.is_a?(Array) && result.first.is_a?(Hash)
          result.first
        elsif result.is_a?(Hash)
          result
        else
          { label: "unknown", score: 0.0 }
        end

        message = ActiveAgent::ActionPrompt::Message.new(
          role: "assistant",
          content: sentiment_data
        )

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: @prompt,
          message: message,
          raw_response: result,
          raw_request: { input: input_text, config: @config }
        )

        update_context(prompt: @prompt, message: message, response: @response)
        @response
      end

      def handle_qa_response(result, input_data)
        # Format QA response
        answer = if result.is_a?(Hash)
          result["answer"] || result[:answer] || result.to_s
        else
          result.to_s
        end

        message = ActiveAgent::ActionPrompt::Message.new(
          role: "assistant",
          content: answer
        )

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: @prompt,
          message: message,
          raw_response: result,
          raw_request: { input: input_data, config: @config }
        )

        update_context(prompt: @prompt, message: message, response: @response)
        @response
      end

      def handle_generic_response(result, input_text)
        # Handle any other pipeline output
        content = if result.is_a?(String)
          result
        elsif result.is_a?(Hash)
          result.to_json
        elsif result.is_a?(Array)
          result.map(&:to_s).join("\n")
        else
          result.to_s
        end

        message = ActiveAgent::ActionPrompt::Message.new(
          role: "assistant",
          content: content
        )

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: @prompt,
          message: message,
          raw_response: result,
          raw_request: { input: input_text, config: @config }
        )

        update_context(prompt: @prompt, message: message, response: @response)
        @response
      end

      def extract_text_from_result(result)
        if result.is_a?(String)
          result
        elsif result.is_a?(Array) && result.first.is_a?(Hash)
          # Pipeline often returns array of hashes
          result.first["generated_text"] || result.first["summary_text"] || result.first["translation_text"] || result.first.values.first.to_s
        elsif result.is_a?(Hash)
          result["generated_text"] || result["summary_text"] || result["translation_text"] || result.values.first.to_s
        else
          result.to_s
        end
      end

      def normalize_embedding(result)
        if result.is_a?(Array)
          # Check if it's already a flat array of numbers
          if result.first.is_a?(Numeric)
            result
          elsif result.first.is_a?(Array)
            # Nested array, take first element or flatten
            result.first
          else
            result.map(&:to_f)
          end
        elsif result.respond_to?(:to_a)
          result.to_a
        elsif result.is_a?(Hash) && result["embeddings"]
          result["embeddings"]
        else
          Array(result)
        end
      end

      def handle_response(response)
        @response
      end

      protected

      def build_provider_parameters
        {
          model: @model_name,
          task: @task,
          model_type: @model_type
        }.compact
      end
    end
  end
end
