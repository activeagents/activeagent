# frozen_string_literal: true

module ActionAgent
  module Api
    # Per-account LLM provider credentials (Settings -> Provider API Keys).
    # API keys are write-only: responses carry a masked hint, never the key.
    # Ollama's credential is a host URL and is echoed back in full. Claude
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
      def create
        provider = params.require(:provider)
        credential = params.require(:credential)

        record = owned(ProviderKey).find_or_initialize_by(provider: provider)
        record.update!(credential: credential)

        render json: { provider_key: serialize(provider, record) }, status: :created
      end

      # DELETE /api/provider_keys/:provider
      def destroy
        owned(ProviderKey).find_by!(provider: params[:provider]).destroy!
        head :no_content
      end

      private

      def serialize(provider, record)
        {
          provider: provider,
          host_based: ProviderKey::HOST_PROVIDERS.include?(provider),
          # "key", "host", or "connection" (Settings -> Integrations rather
          # than Provider API Keys).
          kind: ProviderKey.kind_of_provider(provider),
          configured: record.present?,
          hint: record&.display_hint,
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
