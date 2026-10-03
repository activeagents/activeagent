# frozen_string_literal: true

module ActionAgent
  module Api
    # Model catalogs for the dashboard's model pickers: the agent builder and
    # editor, and the evaluation forms.
    #
    # Hosted providers get a curated list of current models (kept here, server
    # side, so the UI can't drift stale). Ollama is queried live from the
    # caller's effective host (see ProviderCredentials: their personal key,
    # the host resolver's, the account's, falling back to the platform
    # config) so locally pulled models appear; OpenRouter is queried from its
    # public catalog, and Anthropic from its Models API with the caller's
    # effective key. Live lookups fall back to the curated list on any
    # failure, and when the caller's credentials cannot be resolved.
    #
    # When the host app loads RubyLLM, the chat models its registry lists for
    # the provider that take and return text follow: RubyLLM's bundled
    # catalog, or the host's own model table when it configured one. The list
    # stays de-duplicated, and its first id, the builder's preselected
    # default, is always the live or curated one.
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

        render json: { provider: provider, models: (models + registry_models(provider)).uniq, source: source }
      end

      private

      # The caller's effective Ollama endpoint, else the host app's default
      # from config/active_agent.yml.
      def ollama_host
        resolution = credentials("ollama")
        return nil if resolution.nil?

        options = resolution.options
        host = options[:host].presence || options[:base_url].presence || options[:uri_base].presence
        (host || ActiveAgent.configuration[:ollama]&.dig(:host)).presence
      end

      # The caller's effective credentials for +provider+, or nil when they
      # cannot be resolved.
      def credentials(provider)
        @credentials ||= {}
        return @credentials[provider] if @credentials.key?(provider)

        @credentials[provider] = begin
          resolution = ProviderCredentials.resolve(owner: current_owner, actor: current_user, provider: provider)
          resolution.options = resolution.options.symbolize_keys
          resolution
        rescue ProviderCredentials::Unresolved => e
          Rails.logger.warn("[ProviderModels] #{e.message}")
          nil
        end
      end

      def credential_key(provider)
        options = credentials(provider)&.options || {}
        options[:access_token].presence || options[:api_key].presence
      end

      # Same probe as Settings -> "Test connection", so the builder's dropdown
      # and the settings page agree on what the host serves (including the
      # optional Bearer key for remote servers).
      def live_ollama_models
        host = ollama_host
        return nil unless host

        result = OllamaHostProbe.call(host: host, api_key: credential_key("ollama"))
        unless result.ok
          Rails.logger.warn("[ProviderModels] ollama lookup failed: #{result.error}")
          return nil
        end

        [ result.models, "live" ] if result.models.any?
      end

      # Queries the Anthropic Models API with the caller's effective key
      # (newest first, as returned by the API) so new model releases appear
      # without a deploy. The platform's own key is never used here.
      def live_anthropic_models
        key = credential_key("anthropic")
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

      # The whole catalog, never a prefix of it: OpenRouter serves several
      # hundred models, and a cap after sorting left everything late in the
      # alphabet (openai/*, qwen/*, ...) unselectable. The editor filters it.
      def live_openrouter_models
        data = Rails.cache.fetch("provider_models:openrouter", expires_in: 1.hour) do
          fetch_json(URI.parse("https://openrouter.ai/api/v1/models"))
        end
        ids = Array(data&.dig("data")).filter_map { |model| model["id"] }
        [ ids.sort, "live" ] if ids.any?
      rescue StandardError => e
        Rails.logger.warn("[ProviderModels] openrouter lookup failed: #{e.message}")
        nil
      end

      # Returns the ids of the chat models RubyLLM's registry lists for
      # +provider+ that take and return text. Empty without RubyLLM, or when
      # the registry raises. This engine's provider names are RubyLLM's own
      # slugs.
      #
      # `chat_models` alone is not enough: RubyLLM counts a model as a chat
      # model whenever its output modalities name no other kind, none at all
      # included. That takes in the speech, transcription, moderation and
      # completion-only models its registry lists with no modalities, and the
      # transcription models it lists as taking audio. The few chat models it
      # lists with no modalities are left out with them.
      def registry_models(provider)
        return [] unless defined?(::RubyLLM) && ::RubyLLM.respond_to?(:models)

        ::RubyLLM.models.by_provider(provider).chat_models.filter_map do |model|
          modalities = model.modalities
          model.id.presence if Array(modalities&.input).include?("text") && Array(modalities&.output).include?("text")
        end
      rescue StandardError => e
        Rails.logger.warn("[ProviderModels] RubyLLM registry lookup failed: #{e.message}")
        []
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
