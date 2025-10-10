# frozen_string_literal: true

require_relative "base"
require_relative "response"
require_relative "stream_processing"
require_relative "message_formatting"
require_relative "tool_management"

module ActiveAgent
  module GenerationProvider
    class OnnxRuntimeProvider < Base
      include StreamProcessing
      include MessageFormatting
      include ToolManagement

      attr_reader :informer, :embedder, :onnx_model, :tokenizer

      def initialize(config)
        super(config)
        @config = config
        @model_type = config["model_type"] || "generation" # generation, embedding, vision, multimodal, or custom
        @model_path = config["model_path"]
        @model_name = config["model"] || config["model_name"]
        
        setup_model
      end

      def generate(prompt)
        @prompt = prompt
        
        case @model_type
        when "generation"
          generate_text(prompt)
        when "embedding"
          generate_embedding(prompt)
        when "vision"
          process_image(prompt)
        when "multimodal"
          process_multimodal(prompt)
        else
          raise NotImplementedError, "Model type #{@model_type} not supported"
        end
      end

      def embed(prompt)
        @prompt = prompt
        generate_embedding(prompt)
      end

      private

      def setup_model
        case @model_type
        when "generation"
          setup_generation_model
        when "embedding"
          setup_embedding_model
        when "vision"
          setup_vision_model
        when "multimodal"
          setup_multimodal_model
        when "custom"
          setup_custom_model
        else
          raise ArgumentError, "Unknown model type: #{@model_type}"
        end
      end

      def setup_generation_model
        require "informers" unless defined?(Informers)
        
        model_name = @model_name || "Xenova/gpt2"
        
        # Initialize the text generation model
        @informer = case @config["task"]
        when "text2text-generation"
          Informers::Text2TextGeneration.new(model_name)
        when "text-generation", nil
          Informers::TextGeneration.new(model_name)
        when "question-answering"
          Informers::QuestionAnswering.new(model_name)
        when "summarization"
          Informers::Summarization.new(model_name)
        else
          raise ArgumentError, "Unsupported task: #{@config["task"]}"
        end
      rescue LoadError
        raise LoadError, "Please install the 'informers' gem: gem install informers"
      end

      def setup_embedding_model
        if @config["use_informers"]
          require "informers" unless defined?(Informers)
          
          model_name = @model_name || "Xenova/all-MiniLM-L6-v2"
          @embedder = Informers::FeatureExtraction.new(model_name)
        else
          require "onnxruntime" unless defined?(OnnxRuntime)
          
          # Use raw ONNX Runtime for custom embedding models
          model_path = @model_path || raise(ArgumentError, "model_path required for ONNX embedding models")
          @onnx_model = OnnxRuntime::Model.new(model_path)
          
          # Setup tokenizer if provided
          if @config["tokenizer_path"]
            setup_tokenizer(@config["tokenizer_path"])
          end
        end
      rescue LoadError => e
        if e.message.include?("informers")
          raise LoadError, "Please install the 'informers' gem: gem install informers"
        else
          raise LoadError, "Please install the 'onnxruntime' gem: gem install onnxruntime"
        end
      end

      def setup_custom_model
        require "onnxruntime" unless defined?(OnnxRuntime)
        
        model_path = @model_path || raise(ArgumentError, "model_path required for custom ONNX models")
        
        # Configure execution providers if specified
        if @config["execution_providers"]
          session_options = configure_session_options
          @onnx_model = OnnxRuntime::Model.new(model_path, **session_options)
        else
          @onnx_model = OnnxRuntime::Model.new(model_path)
        end
        
        # Setup tokenizer if provided
        if @config["tokenizer_path"]
          setup_tokenizer(@config["tokenizer_path"])
        end
        
        # Log execution provider info if requested
        log_execution_provider_info if @config["log_gpu_usage"]
      rescue LoadError
        raise LoadError, "Please install the 'onnxruntime' gem: gem install onnxruntime"
      end

      def setup_tokenizer(tokenizer_path)
        # This would integrate with a tokenizer library
        # For now, we'll use a simple approach
        @tokenizer = tokenizer_path
      end

      def setup_vision_model
        require "informers" unless defined?(Informers)
        
        model_name = @model_name || "google/vit-base-patch16-224"
        
        @informer = case @config["task"]
        when "image-classification"
          Informers::ImageClassification.new(model_name)
        when "object-detection"
          Informers::ObjectDetection.new(model_name)
        when "image-segmentation"
          Informers::ImageSegmentation.new(model_name)
        else
          Informers::ImageClassification.new(model_name)
        end
      rescue LoadError
        raise LoadError, "Please install the 'informers' gem: gem install informers"
      end

      def setup_multimodal_model
        require "informers" unless defined?(Informers)
        
        model_name = @model_name || "openai/clip-vit-base-patch32"
        
        # Setup both vision and text encoders for multimodal models
        @informer = case @config["task"]
        when "zero-shot-image-classification"
          Informers::ZeroShotImageClassification.new(model_name)
        when "image-text-matching"
          Informers::ImageTextMatching.new(model_name)
        else
          # Default to CLIP-like model
          Informers::ZeroShotImageClassification.new(model_name)
        end
      rescue LoadError
        raise LoadError, "Please install the 'informers' gem: gem install informers"
      end

      def generate_text(prompt)
        input_text = extract_input_text(prompt)
        
        result = if @informer
          # Use Informers for text generation
          options = build_generation_options
          @informer.generate(input_text, **options)
        elsif @onnx_model
          # Use raw ONNX model
          generate_with_onnx_model(input_text)
        else
          raise RuntimeError, "No model initialized for text generation"
        end
        
        handle_text_response(result, input_text)
      end

      def generate_embedding(prompt)
        input_text = extract_input_text(prompt)
        
        embedding = if @embedder
          # Use Informers for embeddings
          @embedder.extract(input_text)
        elsif @onnx_model
          # Use raw ONNX model
          generate_embedding_with_onnx(input_text)
        else
          raise RuntimeError, "No model initialized for embeddings"
        end
        
        handle_embedding_response(embedding, input_text)
      end

      def extract_input_text(prompt)
        if prompt.respond_to?(:message)
          prompt.message.content
        elsif prompt.respond_to?(:messages)
          prompt.messages.map { |m| m.content }.join("\n")
        elsif prompt.is_a?(String)
          prompt
        else
          prompt.to_s
        end
      end

      def build_generation_options
        options = {}
        
        # Map common generation parameters
        options[:max_new_tokens] = @config["max_tokens"] if @config["max_tokens"]
        options[:temperature] = @config["temperature"] if @config["temperature"]
        options[:top_p] = @config["top_p"] if @config["top_p"]
        options[:top_k] = @config["top_k"] if @config["top_k"]
        options[:do_sample] = @config["do_sample"] if @config.key?("do_sample")
        options[:num_beams] = @config["num_beams"] if @config["num_beams"]
        options[:repetition_penalty] = @config["repetition_penalty"] if @config["repetition_penalty"]
        
        options
      end

      def generate_with_onnx_model(input_text)
        # This would need proper tokenization and model-specific preprocessing
        # For now, this is a placeholder
        inputs = prepare_onnx_inputs(input_text)
        outputs = @onnx_model.predict(inputs)
        process_onnx_outputs(outputs)
      end

      def generate_embedding_with_onnx(input_text)
        # Prepare inputs for ONNX model
        inputs = prepare_onnx_inputs(input_text)
        outputs = @onnx_model.predict(inputs)
        
        # Extract embeddings from outputs
        # The exact key depends on the model
        outputs["embeddings"] || outputs["last_hidden_state"] || outputs.values.first
      end

      def prepare_onnx_inputs(text)
        # This would need proper tokenization
        # Placeholder implementation
        {
          "input_ids" => tokenize(text),
          "attention_mask" => create_attention_mask(text)
        }
      end

      def tokenize(text)
        # Simplified tokenization - would need proper tokenizer
        words = text.split
        # Convert to token IDs (placeholder)
        words.map.with_index { |_, i| i }
      end

      def create_attention_mask(text)
        # Create attention mask based on token count
        token_count = text.split.length
        Array.new(token_count, 1)
      end

      def process_onnx_outputs(outputs)
        # Process ONNX model outputs into text
        # This is model-specific and would need proper implementation
        outputs.to_s
      end

      def handle_text_response(result, input_text)
        content = if result.is_a?(String)
          result
        elsif result.respond_to?(:text)
          result.text
        elsif result.is_a?(Hash) && result["generated_text"]
          result["generated_text"]
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

      def process_image(prompt)
        image_input = extract_image_input(prompt)
        
        result = if @informer
          @informer.call(image_input)
        elsif @onnx_model
          process_image_with_onnx(image_input)
        else
          raise RuntimeError, "No model initialized for image processing"
        end
        
        handle_vision_response(result, image_input)
      end

      def process_multimodal(prompt)
        inputs = extract_multimodal_inputs(prompt)
        
        result = if @informer
          # Process based on task type
          case @config["task"]
          when "zero-shot-image-classification"
            @informer.call(inputs[:image], candidate_labels: inputs[:labels])
          when "image-text-matching"
            @informer.call(inputs[:image], inputs[:text])
          else
            @informer.call(inputs)
          end
        elsif @onnx_model
          process_multimodal_with_onnx(inputs)
        else
          raise RuntimeError, "No model initialized for multimodal processing"
        end
        
        handle_multimodal_response(result, inputs)
      end

      def extract_image_input(prompt)
        if prompt.respond_to?(:message)
          content = prompt.message.content
          if content.is_a?(Hash) && content[:image]
            content[:image]
          elsif content.is_a?(String) && (content.start_with?("/") || content.start_with?("http"))
            # Path or URL to image
            content
          else
            raise ArgumentError, "No image input found in prompt"
          end
        else
          prompt.to_s
        end
      end

      def extract_multimodal_inputs(prompt)
        if prompt.respond_to?(:message)
          content = prompt.message.content
          if content.is_a?(Hash)
            {
              image: content[:image] || content["image"],
              text: content[:text] || content["text"],
              labels: content[:labels] || content["labels"] || ["cat", "dog", "bird", "other"]
            }
          else
            raise ArgumentError, "Multimodal input must be a hash with :image and :text keys"
          end
        else
          raise ArgumentError, "Invalid multimodal input format"
        end
      end

      def process_image_with_onnx(image_input)
        # Placeholder for ONNX image processing
        # Would need proper image preprocessing
        inputs = prepare_image_inputs(image_input)
        outputs = @onnx_model.predict(inputs)
        process_vision_outputs(outputs)
      end

      def process_multimodal_with_onnx(inputs)
        # Placeholder for ONNX multimodal processing
        prepared_inputs = prepare_multimodal_inputs(inputs)
        outputs = @onnx_model.predict(prepared_inputs)
        process_multimodal_outputs(outputs)
      end

      def prepare_image_inputs(image_path)
        # Would need proper image loading and preprocessing
        # This is a placeholder
        { "pixel_values" => [] }
      end

      def prepare_multimodal_inputs(inputs)
        # Would need proper preprocessing for both image and text
        { "pixel_values" => [], "input_ids" => [] }
      end

      def process_vision_outputs(outputs)
        # Process vision model outputs
        outputs
      end

      def process_multimodal_outputs(outputs)
        # Process multimodal model outputs
        outputs
      end

      def handle_vision_response(result, image_input)
        content = format_vision_result(result)
        
        message = ActiveAgent::ActionPrompt::Message.new(
          role: "assistant",
          content: content
        )
        
        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: @prompt,
          message: message,
          raw_response: result,
          raw_request: { image: image_input, config: @config }
        )
        
        update_context(prompt: @prompt, message: message, response: @response)
        @response
      end

      def handle_multimodal_response(result, inputs)
        content = format_multimodal_result(result)
        
        message = ActiveAgent::ActionPrompt::Message.new(
          role: "assistant",
          content: content
        )
        
        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: @prompt,
          message: message,
          raw_response: result,
          raw_request: { inputs: inputs, config: @config }
        )
        
        update_context(prompt: @prompt, message: message, response: @response)
        @response
      end

      def format_vision_result(result)
        if result.is_a?(Array)
          # Classification results
          result.map { |r| { label: r["label"], score: r["score"] } }
        elsif result.is_a?(Hash)
          result
        else
          { result: result.to_s }
        end
      end

      def format_multimodal_result(result)
        if result.is_a?(Array)
          result
        elsif result.is_a?(Hash)
          result
        else
          { result: result.to_s }
        end
      end

      def handle_embedding_response(embedding, input_text)
        # Normalize embedding format
        embedding_vector = if embedding.is_a?(Array)
          embedding
        elsif embedding.respond_to?(:to_a)
          embedding.to_a
        elsif embedding.is_a?(Hash) && embedding["embedding"]
          embedding["embedding"]
        else
          Array(embedding)
        end
        
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

      def handle_response(response)
        @response
      end

      def configure_session_options
        options = {}
        
        # Set execution providers
        if @config["execution_providers"]
          options[:execution_providers] = @config["execution_providers"]
        end
        
        # Set provider-specific options (e.g., CoreML settings)
        if @config["provider_options"]
          options[:provider_options] = @config["provider_options"]
        end
        
        # Enable profiling if requested
        if @config["enable_profiling"]
          options[:enable_profiling] = true
        end
        
        # Set graph optimization level
        if @config["graph_optimization_level"]
          options[:graph_optimization_level] = @config["graph_optimization_level"]
        end
        
        options
      end

      def log_execution_provider_info
        return unless @onnx_model
        
        begin
          providers = OnnxRuntime::InferenceSession.providers
          active_provider = detect_active_provider
          
          Rails.logger.info "[OnnxRuntime] Available providers: #{providers.join(', ')}"
          Rails.logger.info "[OnnxRuntime] Active provider: #{active_provider}"
          
          if @config["execution_providers"]
            Rails.logger.info "[OnnxRuntime] Requested providers: #{@config['execution_providers'].join(', ')}"
          end
          
          # Log GPU/hardware acceleration info
          if active_provider&.include?("CoreML")
            Rails.logger.info "[OnnxRuntime] CoreML hardware acceleration enabled"
            log_coreml_info
          elsif active_provider&.include?("CUDA")
            Rails.logger.info "[OnnxRuntime] CUDA GPU acceleration enabled"
          elsif active_provider&.include?("DirectML")
            Rails.logger.info "[OnnxRuntime] DirectML GPU acceleration enabled"
          end
        rescue => e
          Rails.logger.warn "[OnnxRuntime] Could not log execution provider info: #{e.message}"
        end
      end

      def detect_active_provider
        # This is a simplified detection - actual implementation would
        # check the model's session to see which provider is active
        if @config["execution_providers"]&.any?
          available = OnnxRuntime::InferenceSession.providers
          @config["execution_providers"].find { |p| available.include?(p) }
        else
          "CPUExecutionProvider"
        end
      rescue
        "Unknown"
      end

      def log_coreml_info
        if @config["provider_options"]&.dig("CoreMLExecutionProvider")
          options = @config["provider_options"]["CoreMLExecutionProvider"]
          Rails.logger.info "[OnnxRuntime] CoreML options:"
          Rails.logger.info "  - CPU only: #{options['use_cpu_only'] == 1}"
          Rails.logger.info "  - Enable on subgraph: #{options['enable_on_subgraph'] == 1}"
          Rails.logger.info "  - ANE only: #{options['only_enable_device_with_ane'] == 1}"
        end
      end

      protected

      def build_provider_parameters
        {
          model: @model_name,
          model_type: @model_type,
          model_path: @model_path
        }.compact
      end
    end
  end
end