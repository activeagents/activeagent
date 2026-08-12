# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # The dashboard's aggregate queries are written portably, but a few of
    # them have a much faster PostgreSQL form (jsonb traversal, containment).
    # This is how those queries choose which one to run.
    module AdapterAware
      extend ActiveSupport::Concern

      class_methods do
        # True when the backing store is PostgreSQL.
        def postgres?
          connection.adapter_name.to_s.downcase.include?("postgres")
        end
      end
    end
  end
end
