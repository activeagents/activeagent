# frozen_string_literal: true

require "test_helper"

module Providers
  class OllamaProviderTest < ActiveSupport::TestCase
    include WebMock::API

    CLOUD_COMPLETIONS = "https://ollama.com/v1/chat/completions"

    test "basic generation with Ollama" do
      VCR.use_cassette("docs/providers/ollama/basic_generation") do
        # region ollama_basic_example
        response = OllamaAgent.with(
          message: "What is a design pattern?"
        ).ask.generate_now
        # endregion ollama_basic_example

        doc_example_output(response)

        assert response.success?
        assert_not_nil response.message.content
        assert response.message.content.length > 0
      end
    end

    # Ollama Cloud answers like any OpenAI-compatible server; the exchange
    # here is a stand-in for one, so the example runs without a key.
    test "generates on Ollama Cloud with the key from OLLAMA_API_KEY" do
      stub_request(:post, CLOUD_COMPLETIONS).to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-cloud", object: "chat.completion", created: 1_700_000_000, model: "gpt-oss:120b",
          choices: [ { index: 0, finish_reason: "stop",
                       message: { role: "assistant", content: "A reusable solution to a recurring design problem." } } ],
          usage: { prompt_tokens: 12, completion_tokens: 11, total_tokens: 23 }
        }.to_json
      )

      with_ollama_api_key("sk-cloud") do
        # region ollama_cloud_example
        response = OllamaCloudAgent.with(
          message: "What is a design pattern?"
        ).ask.generate_now
        # endregion ollama_cloud_example

        assert response.success?
        assert_equal "A reusable solution to a recurring design problem.", response.message.content
        assert_equal 12, response.usage.input_tokens
      end

      assert_requested(:post, CLOUD_COMPLETIONS, headers: { "Authorization" => "Bearer sk-cloud" }) do |request|
        JSON.parse(request.body)["model"] == "gpt-oss:120b"
      end
    end

    test "a cloud request without a key fails before it is sent" do
      with_ollama_api_key(nil) do
        error = assert_raises(ActiveAgent::Providers::Errors::AuthenticationFailed) do
          OllamaCloudAgent.with(message: "Hi").ask.generate_now
        end
        assert_match(/OLLAMA_API_KEY/, error.message)
      end

      assert_not_requested(:post, CLOUD_COMPLETIONS)
    end

    test "lists and describes the models a host serves" do
      stub_request(:get, "https://ollama.com/api/tags")
        .with(headers: { "Authorization" => "Bearer sk-cloud" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { models: [ { name: "gpt-oss:120b", details: { family: "gptoss", parameter_size: "116.8B" } },
                                     { name: "kimi-k3", details: { family: "deepseek2", parameter_size: "1T" } } ] }.to_json)
      stub_request(:post, "https://ollama.com/api/show")
        .with(body: { model: "gpt-oss:120b" }.to_json)
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { details: { family: "gptoss" }, capabilities: %w[completion tools thinking],
                           model_info: { "general.architecture" => "gptoss", "gptoss.context_length" => 131_072 } }.to_json)

      with_ollama_api_key("sk-cloud") do
        # region ollama_model_lookup
        catalog = ActiveAgent::Providers::Ollama::Catalog.new(
          host: "https://ollama.com", api_key: ENV["OLLAMA_API_KEY"]
        )
        names = catalog.models.map(&:name)                 # => ["gpt-oss:120b", "kimi-k3"]
        model = catalog.model_info("gpt-oss:120b")
        model.capabilities                                  # => ["completion", "tools", "thinking"]
        model.context_length                                # => 131072
        model.cloud?                                        # => true
        # endregion ollama_model_lookup

        assert_equal %w[gpt-oss:120b kimi-k3], names
        assert_equal %w[completion tools thinking], model.capabilities
        assert_equal 131_072, model.context_length
        assert model.cloud?
      end
    end

    test "demonstrates advanced options configuration" do
      VCR.use_cassette("docs/providers/ollama/advanced_options") do
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
      VCR.use_cassette("docs/providers/ollama/model_loading") do
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
      VCR.use_cassette("docs/providers/ollama/gpu_configuration") do
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
      VCR.use_cassette("docs/providers/ollama/quantized_model") do
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

        rescue_from ::OpenAI::Errors::APIConnectionError do |error|
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

      VCR.use_cassette("docs/providers/ollama/error_handling") do
        response = RobustOllamaAgent.with(message: "Hi!").ask.generate_now

        assert response.success?
        assert_not_nil response.message.content
      end
    end

    private

    # Sets OLLAMA_API_KEY for the block (nil unsets it) and restores it.
    def with_ollama_api_key(value)
      previous = ENV["OLLAMA_API_KEY"]
      value.nil? ? ENV.delete("OLLAMA_API_KEY") : ENV["OLLAMA_API_KEY"] = value
      yield
    ensure
      previous.nil? ? ENV.delete("OLLAMA_API_KEY") : ENV["OLLAMA_API_KEY"] = previous
    end
  end
end
