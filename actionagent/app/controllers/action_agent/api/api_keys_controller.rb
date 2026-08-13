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
      def create
        api_key = owned(ApiKey).create!(name: params.require(:name))

        render json: {
          api_key: serialize(api_key).merge(token: api_key.token)
        }, status: :created
      end

      # DELETE /api/api_keys/:id
      def destroy
        owned(ApiKey).find(params[:id]).destroy!
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
