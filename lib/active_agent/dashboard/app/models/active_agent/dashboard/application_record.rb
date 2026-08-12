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

      # Models that are not themselves owned still answer the ownership
      # questions, so callers can scope any dashboard relation uniformly.
      class << self
        def owner_association = nil
        def for_owner(_owner) = all
      end
    end
  end
end
