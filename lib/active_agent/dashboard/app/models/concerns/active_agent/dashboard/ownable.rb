# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Attaches a dashboard record to whatever the host app calls an owner.
    #
    # Multi-tenant installs own records through an Account, single-tenant
    # installs through a User, and a single-user self-hosted install owns
    # nothing at all — the associations simply aren't declared, so the engine
    # boots in an app with no User model.
    #
    # Both foreign keys exist in the engine's schema either way, so switching
    # a deployment between modes is a configuration change, not a migration.
    module Ownable
      extend ActiveSupport::Concern

      included do
        if ActiveAgent::Dashboard.account_class
          belongs_to :account, class_name: ActiveAgent::Dashboard.account_class, optional: true
        end

        if ActiveAgent::Dashboard.user_class
          belongs_to :user, class_name: ActiveAgent::Dashboard.user_class, optional: true
        end

        scope :owned_by, ->(owner) { for_owner(owner) }
      end

      # The record's owner under the current mode, or nil when unowned.
      def owner
        if ActiveAgent::Dashboard.multi_tenant?
          respond_to?(:account) ? account : nil
        else
          respond_to?(:user) ? user : nil
        end
      end

      # Assigns +owner+ to whichever association this mode uses. Ignored when
      # the host app configured no owner model.
      def owner=(record)
        if ActiveAgent::Dashboard.multi_tenant?
          self.account = record if respond_to?(:account=)
        elsif respond_to?(:user=)
          self.user = record
        end
      end
    end
  end
end
