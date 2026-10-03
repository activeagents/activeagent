# frozen_string_literal: true

module ActionAgent
  module Api
    # Per-account LLM provider credentials (Settings -> Provider API Keys).
    # API keys are write-only: responses carry a masked hint, never the key.
    # Ollama's credential is a host URL and is echoed back in full; its
    # optional API key (remote servers) is masked like the others. Claude
    # Code's connection API key is stored here too, write-only like a key.
    class ProviderKeysController < BaseController
      before_action :require_owner!

      # GET /api/provider_keys — one row per supported provider, configured or not.
      def index
        configured = owned(ProviderKey).index_by(&:provider)

        render json: {
          provider_keys: ProviderKey::PROVIDERS.map do |provider|
            serialize(provider, configured[provider])
          end
        }
      end

      # POST /api/provider_keys — upserts the credential for a provider.
      # Host-based providers may also carry an optional api_key; omitting it
      # keeps the stored one, sending an empty string clears it.
      def create
        provider = params.require(:provider)
        record = owned(ProviderKey).find_or_initialize_by(provider: provider)
        return unless authorize_action!(:manage_credentials, record)

        attributes = { credential: params.require(:credential) }
        attributes[:api_key] = params[:api_key].presence if params.key?(:api_key) && record.host_based?
        record.update!(**attributes)

        render json: { provider_key: serialize(provider, record) }, status: :created
      end

      # POST /api/provider_keys/test — checks that a host-based provider is
      # reachable and lists the models it serves. Tests the submitted host
      # (and api_key) when given, so a URL can be checked before saving;
      # otherwise the stored credential, else the host app's default. Never
      # persists anything.
      def test
        provider = params.require(:provider)
        unless ProviderKey::HOST_PROVIDERS.include?(provider)
          return render json: { error: "#{provider} is not a host-based provider" }, status: :unprocessable_entity
        end

        stored = owned(ProviderKey).find_by(provider: provider)
        return unless authorize_action!(:manage_credentials, stored || owned(ProviderKey).new(provider: provider))

        host = params[:credential].presence || stored&.credential || platform_host(provider)
        api_key = params.key?(:api_key) ? params[:api_key].presence : stored&.api_key

        if host.blank?
          return render json: { ok: false, host: nil, models: [], latency_ms: nil, error: "No host configured" }
        end

        render json: OllamaHostProbe.call(host: host, api_key: api_key).to_h
      end

      # DELETE /api/provider_keys/:provider
      def destroy
        record = owned(ProviderKey).find_by!(provider: params[:provider])
        return unless authorize_action!(:manage_credentials, record)

        record.destroy!
        head :no_content
      end

      private

      # The host app's default (config/active_agent.yml, e.g. OLLAMA_HOST)
      # that applies when the owner has not configured their own.
      def platform_host(provider)
        return nil unless ProviderKey::HOST_PROVIDERS.include?(provider)

        config = ActiveAgent.configuration[provider.to_sym]
        config.respond_to?(:[]) ? config[:host].presence : nil
      rescue StandardError
        nil
      end

      def serialize(provider, record)
        host_based = ProviderKey::HOST_PROVIDERS.include?(provider)

        {
          provider: provider,
          host_based: host_based,
          # "key", "host", or "connection" (Settings -> Integrations rather
          # than Provider API Keys).
          kind: ProviderKey.kind_of_provider(provider),
          configured: record.present?,
          hint: record&.display_hint,
          api_key_configured: record&.api_key? || false,
          api_key_hint: record&.api_key_hint,
          platform_default: host_based && record.nil? ? platform_host(provider) : nil,
          # A Claude Code connection still holding a Claude subscription token
          # from an earlier version: never used, and the UI asks for an API
          # key in its place.
          needs_replacing: record.present? && record.needs_replacing?,
          updated_at: record&.updated_at&.iso8601
        }
      end
    end
  end
end
