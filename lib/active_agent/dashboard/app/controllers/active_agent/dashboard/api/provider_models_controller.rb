# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    module Api
      # Model catalogs for the agent builder/editor dropdowns.
      #
      # Hosted providers get a curated list of current models (kept here, server
      # side, so the UI can't drift stale). Ollama is queried live from the
      # account's configured host (Settings -> Provider API Keys, falling back to
      # the platform config) so locally pulled models appear; OpenRouter is
      # queried from its public catalog. Live lookups fall back to the curated
      # list on any failure.
      class ProviderModelsController < BaseController
        before_action :require_owner!

        FETCH_TIMEOUT_SECONDS = 4

        # Fallbacks when a live lookup isn't possible (reviewed 2026-07). First
        # entry is the default the builder preselects.
        CURATED = {
          "openai" => %w[gpt-5.1 gpt-5 gpt-5-mini gpt-5-nano],
          "anthropic" => %w[claude-opus-5 claude-fable-5 claude-sonnet-5 claude-opus-4-8 claude-haiku-4-5],
          "openrouter" => %w[anthropic/claude-sonnet-4.5 openai/gpt-5.1 meta-llama/llama-3.3-70b-instruct qwen/qwen3-32b],
          "ollama" => %w[qwen3:8b llama3.2 mistral gemma3]
        }.freeze

        # GET /api/provider_models?provider=ollama
        def index
          provider = params[:provider].to_s
          unless Agent::PROVIDERS.include?(provider)
            return render json: { error: "Unknown provider: #{provider}" }, status: :unprocessable_entity
          end

          models, source = case provider
          when "ollama" then live_ollama_models
          when "openrouter" then live_openrouter_models
          when "anthropic" then live_anthropic_models
          end

          if models.blank?
            models = CURATED.fetch(provider)
            source = "curated"
          end

          render json: { provider: provider, models: models, source: source }
        end

        private

        # The owner's configured Ollama endpoint, else the host app's default
        # from config/active_agent.yml.
        def ollama_host
          key = owner_provider_key("ollama")
          host = key&.credential.presence || ActiveAgent.configuration[:ollama]&.dig(:host)
          host.presence
        end

        def owner_provider_key(provider)
          owned(ProviderKey).find_by(provider: provider)
        end

        def live_ollama_models
          host = ollama_host
          return nil unless host

          data = fetch_json(URI.join("#{host.chomp('/')}/", "models"))
          ids = Array(data&.dig("data")).filter_map { |model| model["id"] }
          [ ids.sort, "live" ] if ids.any?
        rescue StandardError => e
          Rails.logger.warn("[ProviderModels] ollama lookup failed: #{e.message}")
          nil
        end

        # Queries the Anthropic Models API with the account's key (newest first,
        # as returned by the API) so new model releases appear without a deploy.
        def live_anthropic_models
          key = current_user_provider_key("anthropic")&.credential
          return nil if key.blank?

          data = Rails.cache.fetch("provider_models:anthropic:#{Digest::SHA256.hexdigest(key)}", expires_in: 1.hour) do
            uri = URI.parse("https://api.anthropic.com/v1/models?limit=50")
            response = Net::HTTP.start(
              uri.host, uri.port,
              use_ssl: true, open_timeout: FETCH_TIMEOUT_SECONDS, read_timeout: FETCH_TIMEOUT_SECONDS
            ) { |http| http.get(uri.request_uri, { "x-api-key" => key, "anthropic-version" => "2023-06-01" }) }
            response.code.to_i == 200 ? JSON.parse(response.body) : nil
          end
          ids = Array(data&.dig("data")).filter_map { |model| model["id"] }
          [ ids, "live" ] if ids.any?
        rescue StandardError => e
          Rails.logger.warn("[ProviderModels] anthropic lookup failed: #{e.message}")
          nil
        end

        def live_openrouter_models
          data = Rails.cache.fetch("provider_models:openrouter", expires_in: 1.hour) do
            fetch_json(URI.parse("https://openrouter.ai/api/v1/models"))
          end
          ids = Array(data&.dig("data")).filter_map { |model| model["id"] }
          [ ids.sort.first(100), "live" ] if ids.any?
        rescue StandardError => e
          Rails.logger.warn("[ProviderModels] openrouter lookup failed: #{e.message}")
          nil
        end

        def fetch_json(uri)
          response = Net::HTTP.start(
            uri.host, uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: FETCH_TIMEOUT_SECONDS,
            read_timeout: FETCH_TIMEOUT_SECONDS
          ) { |http| http.get(uri.request_uri) }
          return nil unless response.code.to_i == 200

          JSON.parse(response.body)
        end
      end
    end
  end
end
