# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Base class for all Dashboard engine models.
    #
    # Table names come from ActiveAgent::Dashboard.table_name_prefix through
    # Rails' standard namespaced-model resolution, so the engine's own
    # migrations (active_agent_agents, active_agent_agent_runs, ...) and a
    # host app that already owns the tables unprefixed are both supported
    # without touching the models.
    #
    # Ownership is configurable: multi-tenant installs scope records to an
    # Account, single-tenant installs to a User, and a single-user install
    # scopes to nothing at all.
    class ApplicationRecord < ::ActiveRecord::Base
      include AdapterAware

      self.abstract_class = true

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

          if ActiveAgent::Dashboard.multi_tenant? && column_names.include?("account_id")
            where(account_id: owner.id)
          elsif column_names.include?("user_id")
            where(user_id: owner.id)
          else
            all
          end
        end
      end
    end
  end
end
