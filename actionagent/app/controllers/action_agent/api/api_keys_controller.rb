# frozen_string_literal: true

module ActionAgent
  module Api
    # Platform API keys (Settings -> API Keys). The full token is returned
    # exactly once — in the create response — and masked everywhere else.
    class ApiKeysController < BaseController
      before_action :require_owner!

      # GET /api/api_keys
      def index
        render json: {
          api_keys: owned(ApiKey).order(created_at: :desc).map { |key| serialize(key) }
        }
      end

      # POST /api/api_keys
      #
      # The key records the user who created it, so a call made with an
      # account's key acts as that user rather than as the whole account.
      def create
        api_key = owned(ApiKey).new(name: params.require(:name))
        api_key.user_id = current_user.id if ActionAgent.user_class.present? && current_user.respond_to?(:id)
        return unless authorize_action!(:manage_api_keys, api_key)

        api_key.save!

        render json: {
          api_key: serialize(api_key).merge(token: api_key.token)
        }, status: :created
      end

      # DELETE /api/api_keys/:id
      def destroy
        api_key = owned(ApiKey).find(params[:id])
        return unless authorize_action!(:manage_api_keys, api_key)

        api_key.destroy!
        head :no_content
      end

      private

      def serialize(api_key)
        {
          id: api_key.id,
          name: api_key.name,
          masked_token: api_key.masked_token,
          created_at: api_key.created_at.iso8601,
          last_used_at: api_key.last_used_at&.iso8601
        }
      end
    end
  end
end
