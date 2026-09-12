# frozen_string_literal: true

module ActiveAgent
  module Generators
    # Writes a starter ActiveAgent::SchemaTools class for one model:
    #
    #   bin/rails generate active_agent:schema_tools Reservation
    #
    # The class it writes exposes nothing beyond +id+ until someone uncomments
    # a column, because which columns an agent may filter on and read back is
    # a judgement about exposure, not a fact about the table (#440). Every
    # column the model has is listed, commented out, minus the ones that look
    # like secrets, so the allowlist is a review step rather than a blank page.
    class SchemaToolsGenerator < ::Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      # Columns never suggested, whatever the model: reading one back would
      # hand a model a credential, and filtering on one leaks it a character
      # at a time through the row counts.
      SECRET_COLUMNS = /password|digest|token|secret|api_key|otp|encrypted|ssn/i

      class_option :policy, type: :boolean, default: nil,
        desc: "Scope every read through <Model>Policy::Scope (default: when that policy exists)"

      check_class_collision suffix: "Tools"

      def create_tools_file
        template "schema_tools.rb.tt", File.join("app/agent_tools", class_path, "#{file_name}_tools.rb")
      end

      private

      # "Reservation" and "ReservationTools" both name the Reservation model.
      def file_name # :doc:
        @_file_name ||= super.sub(/_tools\z/i, "")
      end

      def model_class
        @model_class ||= class_name.safe_constantize
      end

      def policy_class_name
        "#{class_name}Policy"
      end

      def policy?
        return options[:policy] unless options[:policy].nil?

        "#{policy_class_name}::Scope".safe_constantize.present?
      end

      # [name, type] for every column the model has, or [] when the model or
      # its table cannot be read from here (a model that does not exist yet,
      # or a database that is not set up) — the file is still written.
      def columns
        @columns ||= begin
          if model_class.respond_to?(:columns) && model_class.respond_to?(:table_exists?) && model_class.table_exists?
            model_class.columns.map { |column| [ column.name, column.type ] }
          else
            []
          end
        rescue StandardError
          []
        end
      end

      def suggested_columns
        columns.reject { |name, _type| name == "id" || name.match?(SECRET_COLUMNS) }
      end

      def secret_columns
        columns.select { |name, _type| name.match?(SECRET_COLUMNS) }.map(&:first)
      end

      def collection_name
        class_name.demodulize.underscore.pluralize
      end

      def resource_name
        class_name.demodulize.underscore
      end
    end
  end
end
