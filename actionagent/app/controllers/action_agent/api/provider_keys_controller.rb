# frozen_string_literal: true

module ActionAgent
  module Api
    # LLM provider credentials (Settings -> Provider API Keys, and the
    # Organization view's Provider keys). API keys are write-only: responses
    # carry a masked hint, never the key. Ollama's credential is a host URL
    # and is echoed back in full; its optional API key (remote servers) is
    # masked like the others. Claude Code's connection API key is stored here
    # too, write-only like a key.
    #
    # Every action takes a `scope` param:
    #
    #   organization  (default) the owner's shared keys. Writes and tests
    #                 ask permission_checker for :manage_credentials.
    #   personal      the signed-in user's own keys for the owner. Only
    #                 that user's rows are read or changed, writes need no
    #                 permission, and every write and test is refused with
    #                 422 unless ProviderKey.personal_keys_enabled?.
    class ProviderKeysController < BaseController
      SCOPES = %w[organization personal].freeze

      before_action :require_owner!
      before_action :require_known_scope!
      before_action :require_personal_keys!, only: %i[create test destroy], if: :personal_scope?

      # GET /api/provider_keys — one row per supported provider in the
      # requested scope, configured or not.
      #
      # Beside the rows:
      #   scope                         the scope listed
      #   personal_keys_enabled         whether members may keep personal keys
      #   can_manage_organization_keys  whether the caller may change the
      #                                 organization's keys
      def index
        configured = scoped_keys.to_a.index_by(&:provider)
        setters = setters_for(configured.values)

        render json: {
          scope: requested_scope,
          personal_keys_enabled: ProviderKey.personal_keys_enabled?,
          can_manage_organization_keys: ActionAgent.permitted?(current_user, :manage_credentials, owned(ProviderKey).new),
          provider_keys: ProviderKey::PROVIDERS.map do |provider|
            serialize(provider, configured[provider], setters)
          end
        }
      end

      # POST /api/provider_keys — upserts the credential for a provider.
      # Host-based providers may also carry an optional api_key; omitting it
      # keeps the stored one, sending an empty string clears it.
      def create
        provider = params.require(:provider)
        record = scoped_keys.find_or_initialize_by(provider: provider)
        return unless authorize_write!(record)

        attributes = { credential: params.require(:credential), set_by_id: signed_in_user&.id }
        attributes[:api_key] = params[:api_key].presence if params.key?(:api_key) && record.host_based?
        record.update!(**attributes)

        render json: { provider_key: serialize(provider, record, setters_for([ record ])) }, status: :created
      end

      # POST /api/provider_keys/test — checks that a host-based provider is
      # reachable and lists the models it serves. Tests the submitted host
      # (and api_key) when given, so a URL can be checked before saving;
      # otherwise the scope's stored host, else the host app's default.
      # Never persists anything.
      #
      # The stored api_key is sent only to the stored host: a submitted host
      # that normalizes to anything else is probed with the submitted
      # api_key, or with none.
      def test
        provider = params.require(:provider)
        unless ProviderKey::HOST_PROVIDERS.include?(provider)
          return render json: { error: "#{provider} is not a host-based provider" }, status: :unprocessable_entity
        end

        stored = scoped_keys.find_by(provider: provider)
        return unless authorize_write!(stored || scoped_keys.new(provider: provider))

        host = params[:credential].presence || stored&.credential || platform_host(provider)
        if host.blank?
          return render json: { ok: false, host: nil, models: [], latency_ms: nil, error: "No host configured" }
        end

        render json: OllamaHostProbe.call(host: host, api_key: probe_api_key(stored, host)).to_h
      end

      # DELETE /api/provider_keys/:provider
      def destroy
        record = scoped_keys.find_by!(provider: params[:provider])
        return unless authorize_write!(record)

        record.destroy!
        head :no_content
      end

      private

      def requested_scope
        @requested_scope ||= params[:scope].presence || "organization"
      end

      def personal_scope?
        requested_scope == "personal"
      end

      def require_known_scope!
        return if SCOPES.include?(requested_scope)

        render json: { error: "scope must be one of #{SCOPES.join(', ')}" }, status: :unprocessable_entity
      end

      def require_personal_keys!
        return if personal_keys_writable?

        render json: {
          error: "Personal provider keys are not enabled on this dashboard",
          code: "personal_keys_disabled"
        }, status: :unprocessable_entity
      end

      # Whether the signed-in user can hold personal keys here. The owner has
      # to resolve to an account, or a personal write would have no account
      # to belong to.
      def personal_keys_writable?
        ProviderKey.personal_keys_enabled? && signed_in_user.present? && ProviderKey.resolve_owner(current_owner).present?
      end

      # The keys of the requested scope: the organization's, or the signed-in
      # user's own.
      def scoped_keys
        personal_scope? ? ProviderKey.personal_for(current_owner, signed_in_user) : owned(ProviderKey)
      end

      # The signed-in user, when it is an instance of the configured user
      # class: the only caller that can hold personal keys or be recorded as
      # a key's setter.
      def signed_in_user
        user_class = ProviderKey.owner_class_for(:user)
        current_user if user_class && current_user.is_a?(user_class)
      end

      # Personal keys are the caller's own and need no permission; the
      # organization's ask for :manage_credentials.
      def authorize_write!(record)
        personal_scope? || authorize_action!(:manage_credentials, record)
      end

      def probe_api_key(stored, host)
        return params[:api_key].presence if params.key?(:api_key)
        return nil if stored.nil?

        stored.api_key if ProviderKey.normalize_host(host) == ProviderKey.normalize_host(stored.credential)
      end

      # The users who last saved +records+, by id, read in one query.
      def setters_for(records)
        ids = records.filter_map(&:set_by_id).uniq
        user_class = ProviderKey.owner_class_for(:user)
        return {} if ids.empty? || user_class.nil?

        user_class.where(id: ids).index_by(&:id)
      end

      # The source the caller's own runs use for +provider+, or nil for a
      # connection credential, which no run generates on, and when the
      # caller's credentials cannot be resolved.
      def effective_source(provider)
        return nil if ProviderKey::CONNECTION_PROVIDERS.include?(provider)

        ProviderCredentials.resolve(owner: current_owner, actor: current_user, provider: provider).source
      rescue ProviderCredentials::Unresolved
        nil
      end

      # The host app's default (config/active_agent.yml, e.g. OLLAMA_HOST)
      # that applies when the owner has not configured their own.
      def platform_host(provider)
        return nil unless ProviderKey::HOST_PROVIDERS.include?(provider)

        config = ActiveAgent.configuration[provider.to_sym]
        config.respond_to?(:[]) ? config[:host].presence : nil
      rescue StandardError
        nil
      end

      def serialize(provider, record, setters)
        host_based = ProviderKey::HOST_PROVIDERS.include?(provider)
        setter = record&.set_by_id && setters[record.set_by_id]

        {
          provider: provider,
          scope: requested_scope,
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
          effective_source: effective_source(provider),
          set_by: setter && { id: setter.id, name: display_name(setter) },
          updated_at: record&.updated_at&.iso8601
        }
      end

      def display_name(user)
        user.try(:display_name) || user.try(:name) || user.try(:email_address) || user.try(:email)
      end
    end
  end
end
