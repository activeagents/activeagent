# frozen_string_literal: true

require "test_helper"

class Providers::OllamaProviderTest < ActiveSupport::TestCase
  test "basic generation with Ollama" do
    VCR.use_cassette("providers/ollama/basic_generation") do
      # region ollama_basic_example
      response = Providers::OllamaAgent.with(
        message: "What is a design pattern?"
      ).ask.generate_now
      # endregion ollama_basic_example

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
      assert response.message.content.length > 0
    end
  end

  test "demonstrates advanced options configuration" do
    VCR.use_cassette("providers/ollama/advanced_options") do
      # Example of advanced Ollama configuration
      # region ollama_advanced_options
      class AdvancedOllamaAgent < ApplicationAgent
        generate_with :ollama,
          model: "llama3",
          temperature: 0.7,
          options: {
            num_ctx: 4096,         # Context window size
            num_gpu: 1,            # Number of GPUs to use
            num_thread: 8,         # Number of threads
            repeat_penalty: 1.1,   # Penalize repetition
            mirostat: 2,           # Mirostat sampling
            mirostat_tau: 5.0,     # Mirostat tau parameter
            mirostat_eta: 0.1      # Mirostat learning rate
          }

        def ask
          prompt(message: params[:message])
        end
      end
      # endregion ollama_advanced_options

      response = AdvancedOllamaAgent.with(message: "What is 2+2?").ask.generate_now

      assert response.success?
      assert_not_nil response.message.content
    end
  end


  test "demonstrates model loading configuration" do
    VCR.use_cassette("providers/ollama/model_loading") do
      # Keep models in memory for faster responses
      # region ollama_model_loading
      class FastOllamaAgent < ApplicationAgent
        generate_with :ollama,
          model: "llama3",
          keep_alive: "5m"  # Keep model loaded for 5 minutes

        def quick_response
          prompt(message: params[:query])
        end
      end
      # endregion ollama_model_loading

      response = FastOllamaAgent.with(query: "Hello!").quick_response.generate_now

      assert response.success?
      assert_not_nil response.message.content
    end
  end


  test "demonstrates GPU configuration" do
    VCR.use_cassette("providers/ollama/gpu_configuration") do
      # Configure GPU usage for better performance
      # region ollama_gpu_configuration
      class GPUAgent < ApplicationAgent
        generate_with :ollama,
          model: "llama3",
          options: {
            num_gpu: -1,  # Use all available GPUs
            main_gpu: 0   # Primary GPU index
          }

        def ask
          prompt(message: params[:message])
        end
      end
      # endregion ollama_gpu_configuration

      response = GPUAgent.with(message: "What is 5+5?").ask.generate_now

      assert response.success?
      assert_not_nil response.message.content
    end
  end

  test "demonstrates quantized model usage" do
    VCR.use_cassette("providers/ollama/quantized_model") do
      # Use quantized model for faster inference
      # region ollama_quantized_model
      class EfficientAgent < ApplicationAgent
        # Use quantized model for faster inference
        generate_with :ollama, model: "qwen3:0.6b"

        def ask
          prompt(message: params[:message])
        end
      end
      # endregion ollama_quantized_model

      response = EfficientAgent.with(message: "Count to three").ask.generate_now

      assert response.success?
      assert_not_nil response.message.content
    end
  end


  test "demonstrates error handling pattern" do
    # Ollama-specific error handling
    # region ollama_error_handling
    class RobustOllamaAgent < ApplicationAgent
      generate_with :ollama, model: "llama3"

      rescue_from Faraday::ConnectionFailed do |error|
        Rails.logger.error "Ollama not running: #{error.message}"
        "Ollama is not running. Start it with: ollama serve"
      end

      rescue_from StandardError do |error|
        if error.message.include?("model not found")
          # Pull the model if it's not found
          # system("ollama pull #{generation_provider.model}")
          raise error  # Re-raise for this example
        else
          raise
        end
      end

      def ask
        prompt(message: params[:message])
      end
    end
    # endregion ollama_error_handling

    VCR.use_cassette("providers/ollama/error_handling") do
      response = RobustOllamaAgent.with(message: "Hi!").ask.generate_now

      assert response.success?
      assert_not_nil response.message.content
    end
  end
end
