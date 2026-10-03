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
    #
    # --filterable and --returns write that review's outcome instead: the
    # columns named are declared, and only those. --managed heads the file
    # with ActiveAgent::SchemaTools::MANAGED_MARKER, which a dashboard
    # project's boots look for before they rewrite or remove it.
    class SchemaToolsGenerator < ::Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      # Columns never suggested or written, whatever the model.
      SECRET_COLUMNS = ActiveAgent::SchemaTools::SECRET_COLUMNS

      class_option :policy, type: :boolean, default: nil,
        desc: "Scope every read through <Model>Policy::Scope (default: when that policy exists)"
      class_option :filterable, type: :array, default: nil,
        desc: "Columns an agent may filter on, declared rather than suggested"
      class_option :returns, type: :array, default: nil,
        desc: "Columns an agent may read back, declared rather than suggested"
      class_option :managed, type: :boolean, default: false,
        desc: "Head the file with ActiveAgent::SchemaTools::MANAGED_MARKER, for a dashboard project that rewrites it"

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

      # The columns --filterable or --returns (+option+) declares, after +id+:
      # nil when the option is not given. A column that looks like a secret,
      # or that the model's table does not have when it can be read, is
      # left out with a note.
      def declared_columns(option)
        names = options[option]
        return nil if names.nil?

        known = columns.map(&:first)
        names.map(&:to_s).uniq.reject { |name| name == "id" }.select do |name|
          if name.match?(SECRET_COLUMNS)
            say_status :skip, "#{name}: looks like a secret, so it is not declared", :yellow
            false
          elsif known.any? && !known.include?(name)
            say_status :skip, "#{name}: #{class_name} has no such column", :yellow
            false
          else
            true
          end
        end
      end

      def column_list(names)
        [ "id", *names ].map { |name| ":#{name}" }.join(", ")
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
