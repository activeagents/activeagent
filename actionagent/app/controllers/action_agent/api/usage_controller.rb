# frozen_string_literal: true

module ActionAgent
  module Api
    # The plan meter the Organization view and the Run Agents quota banner
    # read. Both were extracted from the platform along with the route they
    # fetch, but the engine never gained the route, so every visit to either
    # view logged a 404.
    #
    # The engine meters nothing itself. A host that tracks usage against a
    # plan answers through ActionAgent.usage_resolver; a bare mount reports
    # unlimited, in the same shape, so the views can hide the meter.
    class UsageController < BaseController
      # GET /api/usage
      def show
        render json: { usage: ActionAgent.usage_for(current_owner) }
      end
    end
  end
end
