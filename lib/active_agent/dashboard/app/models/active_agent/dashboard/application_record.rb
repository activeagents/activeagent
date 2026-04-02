# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Base class for all Dashboard engine models.
    #
    # Provides multi-tenant support when configured, allowing the same models
    # to work in both local (single-tenant) and platform (multi-tenant) modes.
    class ApplicationRecord < ::ActiveRecord::Base
      self.abstract_class = true

      # Override table name calculation to use active_agent_ prefix
      # without the "dashboard_" from the module namespace
      def self.table_name
        @table_name ||= "active_agent_#{name.demodulize.underscore.pluralize}"
      end

      class << self
        # Returns the owner association name based on configuration.
        # In multi-tenant mode, this returns :account.
        # In local mode, this returns :user (optional).
        def owner_association
          if ActiveAgent::Dashboard.multi_tenant?
            :account
          else
            :user
          end
        end

        # Scopes records to the current owner (account or user).
        # No-op in local mode without owner configuration.
        def for_owner(owner)
          return all if owner.nil?

          if ActiveAgent::Dashboard.multi_tenant?
            where(account: owner)
          elsif column_names.include?("user_id")
            where(user: owner)
          else
            all
          end
        end
      end
    end
  end
end
