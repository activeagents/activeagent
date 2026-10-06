# frozen_string_literal: true

module ActionAgent
  module Api
    # The members of the signed-in owner, for the Organization view's Team
    # Members table. The engine keeps no memberships: the host lists them
    # through ActionAgent.members_resolver, and each member carries only
    # id, name, email and role.
    class MembersController < BaseController
      before_action :require_owner!

      # GET /api/members — { members: [{ id, name, email, role }] }. With no
      # resolver, or one that raised, the signed-in user alone: as "owner" on
      # a single-tenant install, with no role on a multi-tenant one, where
      # the engine cannot know it.
      def index
        members = ActionAgent.members_for(current_owner) || signed_in_member

        render json: { members: members }
      end

      private

      def signed_in_member
        return [] if current_user.nil?

        [ {
          id: current_user.try(:id),
          name: current_user.try(:display_name) || current_user.try(:name) || current_user.try(:email_address),
          email: current_user.try(:email_address) || current_user.try(:email),
          role: ActionAgent.multi_tenant? ? nil : "owner"
        } ]
      end
    end
  end
end
