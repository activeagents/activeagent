# frozen_string_literal: true

require "test_helper"
require "ostruct"

class Providers::OpenRouterProviderTest < ActiveSupport::TestCase
  test "basic generation with OpenRouter" do
    VCR.use_cassette("providers/open_router/basic_generation") do
      # region openrouter_basic_example
      response = Providers::OpenRouterAgent.with(
        message: "What is functional programming?"
      ).ask.generate_now
      # endregion openrouter_basic_example

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
      assert response.message.content.length > 0
    end
  end

  class ResilientAgent < ApplicationAgent
    # region openrouter_fallback_agent
    generate_with :open_router,
      model: "openai/gpt-4o",
      fallback_models: [ "anthropic/claude-sonnet-4", "google/gemini-pro-1.5" ],
      route: "fallback"
    # endregion openrouter_fallback_agent

    def analyze
      prompt(message: params[:message])
    end
  end

  test "uses fallback models for reliability" do
    VCR.use_cassette("providers/open_router/fallback_models") do
      response = ResilientAgent.with(
        message: "Explain polymorphism in OOP"
      ).analyze.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end

  class OptimizedAgent < ApplicationAgent
    # region openrouter_provider_preferences_agent
    generate_with :open_router,
      model: "openrouter/auto",
      provider: {
        data_collection: "deny",      # Privacy-first providers only
        allow_fallbacks: true,         # Enable backup providers
        require_parameters: false      # Flexible parameter support
      }
    # endregion openrouter_provider_preferences_agent

    def chat
      prompt(message: params[:message])
    end
  end

  test "uses provider preferences for privacy" do
    VCR.use_cassette("providers/open_router/provider_preferences") do
      response = OptimizedAgent.with(
        message: "What is encapsulation?"
      ).chat.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end

  class CostOptimizedAgent < ApplicationAgent
    # region openrouter_cost_optimization_agent
    generate_with :open_router,
      model: "openrouter/auto",
      provider: {
        sort: "price",    # Sort by lowest cost
        max_price: {
          prompt: 0.3,    # Max $0.3 per 1M input tokens
          completion: 0.5 # Max $0.5 per 1M output tokens
        }
      }
    # endregion openrouter_cost_optimization_agent

    def generate_response
      prompt(message: params[:message])
    end
  end

  test "optimizes costs with provider sorting" do
    VCR.use_cassette("providers/open_router/cost_optimization") do
      response = CostOptimizedAgent.with(
        message: "Define inheritance"
      ).generate_response.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end

  class LongContextAgent < ApplicationAgent
    generate_with :open_router, model: "openrouter/auto"

    def summarize_document
      long_text = params[:document_text]  # Could be 50K+ tokens

      # region openrouter_transforms_agent
      prompt(
        "Summarize this document:\n\n#{long_text}",
        transforms: [ "middle-out" ]
      )
      # endregion openrouter_transforms_agent
    end
  end

  test "uses middle-out transform for long content" do
    VCR.use_cassette("providers/open_router/transforms") do
      long_document = "The history of programming languages. " * 100

      response = LongContextAgent.with(
        document_text: long_document
      ).summarize_document.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end

  class TrackedAgent < ApplicationAgent
    # region openrouter_user_tracking_agent
    generate_with :open_router,
      model: "openrouter/auto",
      user: -> { Current.user&.id } # Track per-user costs
    # endregion openrouter_user_tracking_agent

    def chat
      prompt(message: params[:message])
    end
  end

  test "tracks costs per user" do
    VCR.use_cassette("providers/open_router/user_tracking") do
      # Simulate a current user
      Current.user = OpenStruct.new(id: "user-123")

      response = TrackedAgent.with(
        message: "Explain abstraction"
      ).chat.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    ensure
      Current.user = nil
    end
  end

  class AttributedAgent < ApplicationAgent
    # region openrouter_app_attribution_agent
    generate_with :open_router,
      model: "openrouter/auto",
      app_name: "MyApp",
      site_url: "https://myapp.com"
    # endregion openrouter_app_attribution_agent

    def chat
      prompt(message: params[:message])
    end
  end

  test "configures application attribution" do
    VCR.use_cassette("providers/open_router/app_attribution") do
      response = AttributedAgent.with(
        message: "What is a design pattern?"
      ).chat.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end

  # region openrouter_vision_agent
  class VisionAgent < ApplicationAgent
    generate_with :open_router,
      model: "openai/gpt-4o"  # Vision-capable model

    def analyze_image
      prompt("What's in this image?", image: params[:image_url])
    end
  end
  # endregion openrouter_vision_agent

  test "analyzes images with vision models" do
    VCR.use_cassette("providers/open_router/vision") do
      response = VisionAgent.with(
        image_url: "https://framerusercontent.com/images/oEx786EYW2ZVL4Xf9hparOVLjHI.png?scale-down-to=64"
      ).analyze_image.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end

  # region openrouter_pdf_agent
  class PDFAgent < ApplicationAgent
    generate_with :open_router,
      model: "openai/gpt-4o"

    def analyze_pdf
      prompt(
        "Summarize this PDF",
        document: params[:pdf_base64_url],
        plugins: [ {
          id: "file-parser",
          pdf: { engine: "pdf-text" }  # Free text extraction
        } ]
      )
    end
  end
  # endregion openrouter_pdf_agent

  test "processes PDF documents" do
    pdf_data = File.read(Rails.root.join("../../docs/public/sample_resume.pdf"))
    pdf_base64 = Base64.strict_encode64(pdf_data)
    pdf_base64_url = "data:application/pdf;base64,#{pdf_base64}"

    VCR.use_cassette("providers/open_router/pdf") do
      response = PDFAgent.with(pdf_base64_url:).analyze_pdf.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end

  class ProviderSelectionAgent < ApplicationAgent
    # region openrouter_provider_selection_agent
    generate_with :open_router,
      model: "openai/gpt-4o-mini",
      provider: {
        order:  [ "openai",   "azure" ],      # Try OpenAI first, then Azure
        only:   [ "openai",   "anthropic" ],  # Limit to specific providers
        ignore: [ "together", "huggingface" ] # Exclude specific providers
      }
    # endregion openrouter_provider_selection_agent

    def chat
      prompt(message: params[:message])
    end
  end

  test "controls provider selection with order and filters" do
    VCR.use_cassette("providers/open_router/provider_selection") do
      response = ProviderSelectionAgent.with(
        message: "Explain dependency injection"
      ).chat.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end

  class PrivacyFirstAgent < ApplicationAgent
    # region openrouter_privacy_agent
    generate_with :open_router,
      model: "openrouter/auto",
      provider: {
        data_collection: "deny",    # Only use privacy-respecting providers
        zdr: true                   # Enable Zero Data Retention
      }
    # endregion openrouter_privacy_agent

    def chat
      prompt(message: params[:message])
    end
  end

  test "respects privacy with data collection controls" do
    VCR.use_cassette("providers/open_router/privacy") do
      response = PrivacyFirstAgent.with(
        message: "Explain the SOLID principles"
      ).chat.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end

  class QuantizedModelAgent < ApplicationAgent
    # region openrouter_quantization_agent
    generate_with :open_router,
      model: "meta-llama/llama-3.1-405b",
      provider: {
        quantizations: [ "fp16", "bf16" ]  # Only use high-precision models
      }
    # endregion openrouter_quantization_agent

    def chat
      prompt(message: params[:message])
    end
  end

  test "filters providers by quantization level" do
    VCR.use_cassette("providers/open_router/quantization") do
      response = QuantizedModelAgent.with(
        message: "What is test-driven development?"
      ).chat.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end

  class AutoRoutingAgent < ApplicationAgent
    # region openrouter_auto_routing_agent
    generate_with :open_router,
      model: "openrouter/auto",  # Let OpenRouter choose
      route: "fallback"          # Enable automatic fallbacks
    # endregion openrouter_auto_routing_agent

    def chat
      prompt(message: params[:message])
    end
  end

  test "uses automatic model routing" do
    VCR.use_cassette("providers/open_router/auto_routing") do
      response = AutoRoutingAgent.with(
        message: "What is a microservice?"
      ).chat.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end

  # Best Practices Examples
  class BestPracticesExamples < ActiveSupport::TestCase
    class ReliableAgent < ApplicationAgent
      generate_with :open_router,
        model: "openai/gpt-4o",
        # region openrouter_best_practice_fallbacks_agent
        fallback_models: [ "anthropic/claude-sonnet-4", "google/gemini-pro-1.5" ]
      # endregion openrouter_best_practice_fallbacks_agent

      def chat
        prompt(message: params[:message])
      end
    end

    test "best practice: uses fallbacks for reliability" do
      VCR.use_cassette("providers/open_router/bp_fallbacks") do
        response = ReliableAgent.with(
          message: "Explain RESTful APIs"
        ).chat.generate_now

        assert response.success?
        assert_not_nil response.message.content
      end
    end

    class CostEfficientAgent < ApplicationAgent
      generate_with :open_router,
        # region openrouter_best_practice_cost_agent
        model: "openrouter/auto",
        provider: {
          sort: "price",
          max_price: { prompt: 0.3, completion: 0.5 }
        }
      # endregion openrouter_best_practice_cost_agent

      def chat
        prompt(message: params[:message])
      end
    end

    test "best practice: optimizes costs with provider preferences" do
      VCR.use_cassette("providers/open_router/bp_cost") do
        response = CostEfficientAgent.with(
          message: "What is GraphQL?"
        ).chat.generate_now

        assert response.success?
        assert_not_nil response.message.content
      end
    end

    class AnalyticsAgent < ApplicationAgent
      generate_with :open_router,
        model: "openai/gpt-4o-mini",
        # region openrouter_best_practice_tracking_agent
        user: -> { Current.user&.id },
        app_name: "MyApp"
      # endregion openrouter_best_practice_tracking_agent

      def chat
        prompt(message: params[:message])
      end
    end

    test "best practice: tracks usage per user" do
      VCR.use_cassette("providers/open_router/bp_tracking") do
        Current.user = OpenStruct.new(id: "user-456")

        response = AnalyticsAgent.with(
          message: "Explain webhooks"
        ).chat.generate_now

        assert response.success?
        assert_not_nil response.message.content
      ensure
        Current.user = nil
      end
    end

    class EfficientContextAgent < ApplicationAgent
      generate_with :open_router,
        model: "openai/gpt-4o-mini"

      def summarize
        prompt(
          message: params[:message],
          # region openrouter_best_practice_transforms_agent
          transforms: [ "middle-out" ]
          # endregion openrouter_best_practice_transforms_agent
        )
      end
    end

    test "best practice: uses transforms for long content" do
      VCR.use_cassette("providers/open_router/bp_transforms") do
        long_content = "API documentation. " * 200

        response = EfficientContextAgent.with(
          message: "Summarize: #{long_content}"
        ).summarize.generate_now

        assert response.success?
        assert_not_nil response.message.content
      end
    end

    class SecureAgent < ApplicationAgent
      generate_with :open_router,
        model: "anthropic/claude-3-5-sonnet",
        # region openrouter_best_practice_privacy_agent
        provider: {
          data_collection: "deny",
          zdr: true
        }
      # endregion openrouter_best_practice_privacy_agent

      def chat
        prompt(message: params[:message])
      end
    end

    test "best practice: respects privacy with provider settings" do
      VCR.use_cassette("providers/open_router/bp_privacy") do
        response = SecureAgent.with(
          message: "Explain OAuth 2.0"
        ).chat.generate_now

        assert response.success?
        assert_not_nil response.message.content
      end
    end
  end
end
