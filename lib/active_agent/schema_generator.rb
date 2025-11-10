# frozen_string_literal: true

module ActiveAgent
  # Provides automatic JSON Schema generation from ActiveRecord and ActiveModel classes.
  #
  # This module can be included in any ActiveRecord or ActiveModel class to add the ability
  # to generate JSON Schema representations. The generated schemas can be used for API
  # documentation, validation, or as input to AI models that support structured outputs.
  #
  # @example Basic usage with ActiveRecord
  #   class User < ApplicationRecord
  #     include ActiveAgent::SchemaGenerator
  #   end
  #
  #   User.to_json_schema
  #   # => { type: "object", properties: { ... }, required: [...] }
  #
  # @example With options
  #   User.to_json_schema(
  #     exclude: [:password_digest],
  #     include_associations: true,
  #     strict: true
  #   )
  #
  # @example ActiveModel usage
  #   class ContactForm
  #     include ActiveModel::Model
  #     include ActiveAgent::SchemaGenerator
  #
  #     attribute :name, :string
  #     attribute :email, :string
  #     attribute :message, :text
  #   end
  #
  #   ContactForm.to_json_schema
  #
  # @see Builder
  module SchemaGenerator
    extend ActiveSupport::Concern

    included do
      if defined?(ActiveRecord::Base) && self < ActiveRecord::Base
        extend ActiveRecordClassMethods
      elsif defined?(ActiveModel::Model) && self.included_modules.include?(ActiveModel::Model)
        extend ActiveModelClassMethods
      else
        # Fallback for any class that includes this module
        extend ActiveModelClassMethods
      end
    end

    # Class methods added to ActiveRecord models.
    module ActiveRecordClassMethods
      # Generates a JSON Schema representation of the ActiveRecord model.
      #
      # @param options [Hash] Options for schema generation
      # @option options [Array<Symbol>] :exclude Attributes to exclude from the schema
      # @option options [Boolean] :include_id (false) Whether to include the id field
      # @option options [Boolean] :include_associations (false) Whether to include associations
      # @option options [Array<Symbol>] :exclude_associations Associations to exclude
      # @option options [Boolean] :nested_associations (false) Whether to include nested association schemas
      # @option options [Boolean] :strict (false) Enable OpenAI strict mode (requires all properties)
      # @option options [String] :name Custom name for the schema (used with strict mode)
      # @option options [Boolean] :additional_properties (false) Allow additional properties in the schema
      #
      # @return [Hash] JSON Schema representation of the model
      #
      # @example Basic schema generation
      #   User.to_json_schema
      #
      # @example Exclude specific fields
      #   User.to_json_schema(exclude: [:password_digest, :created_at])
      #
      # @example Include associations
      #   User.to_json_schema(include_associations: true, nested_associations: true)
      #
      # @example OpenAI strict mode
      #   User.to_json_schema(strict: true, name: "user")
      def to_json_schema(options = {})
        ActiveAgent::SchemaGenerator::Builder.json_schema_from_model(self, options)
      end
    end

    # Class methods added to ActiveModel classes.
    module ActiveModelClassMethods
      # Generates a JSON Schema representation of the ActiveModel class.
      #
      # @param options [Hash] Options for schema generation
      # @option options [Array<Symbol>] :exclude Attributes to exclude from the schema
      # @option options [Boolean] :strict (false) Enable OpenAI strict mode (requires all properties)
      # @option options [String] :name Custom name for the schema (used with strict mode)
      # @option options [Boolean] :additional_properties (false) Allow additional properties in the schema
      #
      # @return [Hash] JSON Schema representation of the model
      #
      # @example Basic schema generation
      #   ContactForm.to_json_schema
      #
      # @example Exclude specific fields
      #   ContactForm.to_json_schema(exclude: [:internal_notes])
      #
      # @example OpenAI strict mode
      #   ContactForm.to_json_schema(strict: true, name: "contact_form")
      def to_json_schema(options = {})
        ActiveAgent::SchemaGenerator::Builder.json_schema_from_model(self, options)
      end
    end

    # Internal builder class for constructing JSON Schemas from model classes.
    #
    # This class handles the actual schema generation logic, supporting both
    # ActiveRecord and ActiveModel classes with various options and configurations.
    #
    # @api private
    class Builder
      # Generates a JSON Schema from a model class.
      #
      # @param model_class [Class] The ActiveRecord or ActiveModel class
      # @param options [Hash] Schema generation options
      #
      # @return [Hash] The generated JSON Schema
      #
      # @raise [ArgumentError] If model_class is not an ActiveRecord or ActiveModel class
      def self.json_schema_from_model(model_class, options = {})
        schema = {
          type: "object",
          properties: {},
          required: [],
          additional_properties: options.fetch(:additional_properties, false)
        }

        if defined?(ActiveRecord::Base) && model_class < ActiveRecord::Base
          schema = build_activerecord_schema(schema, model_class, options)
        elsif defined?(ActiveModel::Model) && model_class.include?(ActiveModel::Model)
          schema = build_activemodel_schema(schema, model_class, options)
        else
          raise ArgumentError, "Model must be an ActiveRecord or ActiveModel class"
        end

        # OpenAI strict mode requires all properties to be in the required array
        # So we add all properties to required if strict mode is enabled
        schema[:required] = schema[:properties].keys.sort if options[:strict]

        {
          name: options[:name] || model_class.name.underscore,
          schema: schema,
          strict: options[:strict]
        }.compact
      end

      class << self
        private

        # Builds a JSON Schema from an ActiveRecord model.
        #
        # Extracts column information, associations, and validations to build
        # a comprehensive schema representation.
        #
        # @param schema [Hash] The schema hash to populate
        # @param model_class [Class] The ActiveRecord model class
        # @param options [Hash] Schema generation options
        #
        # @return [void]
        def build_activerecord_schema(schema, model_class, options)
          model_class.columns.each do |column|
            next if options[:exclude]&.include?(column.name.to_sym)
            next if column.name == "id" && !options[:include_id]

            property = build_property_from_column(column)
            schema[:properties][column.name.to_sym] = property

            if !column.null && column.name != "id"
              schema[:required] << column.name.to_sym
            end
          end

          if model_class.reflect_on_all_associations.any?
            schema = add_associations_to_schema(schema, model_class, options)
          end

          if model_class.respond_to?(:validators)
            schema = add_validations_to_schema(schema, model_class, options)
          end

          schema
        end

        # Builds a JSON Schema from an ActiveModel class.
        #
        # Extracts attribute types and validations to build a schema representation.
        #
        # @param schema [Hash] The schema hash to populate
        # @param model_class [Class] The ActiveModel class
        # @param options [Hash] Schema generation options
        #
        # @return [void]
        def build_activemodel_schema(schema, model_class, options)
          if model_class.respond_to?(:attribute_types)
            model_class.attribute_types.each do |name, type|
              next if options[:exclude]&.include?(name.to_sym)

              property = build_property_from_type(type)
              schema[:properties][name.to_sym] = property
            end
          else
            raise ArgumentError, "#{model_class.name} does not define any attributes. Use `attribute :name, :type` to define attributes."
          end

          if model_class.respond_to?(:validators)
            schema = add_validations_to_schema(schema, model_class, options)
          end

          schema
        end

        # Builds a JSON Schema property definition from an ActiveRecord column.
        #
        # Maps database column types to JSON Schema types and includes metadata
        # like length constraints, formats, and default values.
        #
        # @param column [ActiveRecord::ConnectionAdapters::Column] The database column
        #
        # @return [Hash] JSON Schema property definition
        def build_property_from_column(column)
          property = {
            type: map_sql_type_to_json_type(column.type),
            description: "#{column.name.humanize} field"
          }

          case column.type
          when :string, :text
            if column.limit
              property[:max_length] = column.limit
            end
          when :integer, :bigint
            property[:type] = "integer"
          when :decimal, :float
            property[:type] = "number"
          when :boolean
            property[:type] = "boolean"
          when :date, :datetime, :timestamp
            property[:type] = "string"
            property[:format] = (column.type == :date) ? "date" : "date-time"
          when :json, :jsonb
            property[:type] = "object"
          else
            property[:type] = "string"
          end

          if column.default
            property[:default] = column.default
          end

          property
        end

        # Builds a JSON Schema property definition from an ActiveModel type.
        #
        # @param type [ActiveModel::Type::Value] The ActiveModel type
        #
        # @return [Hash] JSON Schema property definition
        def build_property_from_type(type)
          property = { type: "string" }

          case type
          when ActiveModel::Type::String
            property[:type] = "string"
          when ActiveModel::Type::Integer
            property[:type] = "integer"
          when ActiveModel::Type::Float, ActiveModel::Type::Decimal
            property[:type] = "number"
          when ActiveModel::Type::Boolean
            property[:type] = "boolean"
          when ActiveModel::Type::Date
            property[:type] = "string"
            property[:format] = "date"
          when ActiveModel::Type::DateTime, ActiveModel::Type::Time
            property[:type] = "string"
            property[:format] = "date-time"
          else
            property[:type] = "string"
          end

          property
        end

        # Maps SQL column types to JSON Schema types.
        #
        # @param sql_type [Symbol] The SQL column type
        #
        # @return [String] The corresponding JSON Schema type
        def map_sql_type_to_json_type(sql_type)
          case sql_type
          when :string, :text
            "string"
          when :integer, :bigint
            "integer"
          when :decimal, :float
            "number"
          when :boolean
            "boolean"
          when :json, :jsonb
            "object"
          when :array
            "array"
          else
            "string"
          end
        end

        # Adds association definitions to the schema.
        #
        # Supports has_many, has_one, belongs_to, and has_and_belongs_to_many
        # associations. Can optionally include nested schemas for associated models.
        #
        # @param schema [Hash] The schema hash to populate
        # @param model_class [Class] The ActiveRecord model class
        # @param options [Hash] Schema generation options
        #
        # @return [void]
        def add_associations_to_schema(schema, model_class, options)
          return schema unless options[:include_associations]

          schema[:$defs] ||= {}

          model_class.reflect_on_all_associations.each do |association|
            next if options[:exclude_associations]&.include?(association.name)

            case association.macro
            when :has_many, :has_and_belongs_to_many
              schema[:properties][association.name.to_sym] = {
                type: "array",
                items: { "$ref": "#/$defs/#{association.name.to_s.singularize}" }
              }
              if options[:nested_associations]
                nested_schema = json_schema_from_model(
                  association.klass,
                  options.merge(include_associations: false)
                )
                schema[:$defs][association.name.to_s.singularize.to_sym] = nested_schema
              end
            when :has_one, :belongs_to
              schema[:properties][association.name.to_sym] = {
                "$ref": "#/$defs/#{association.name}"
              }
              if options[:nested_associations]
                nested_schema = json_schema_from_model(
                  association.klass,
                  options.merge(include_associations: false)
                )
                schema[:$defs][association.name.to_sym] = nested_schema
              end
            end
          end

          schema
        end

        # Adds validation constraints to the schema.
        #
        # Translates ActiveModel validations (presence, length, numericality,
        # inclusion, format) into corresponding JSON Schema constraints.
        #
        # @param schema [Hash] The schema hash to populate
        # @param model_class [Class] The model class
        # @param options [Hash] Schema generation options (unused but kept for consistency)
        #
        # @return [void]
        def add_validations_to_schema(schema, model_class, options)
          model_class.validators.each do |validator|
            validator.attributes.each do |attribute|
              next unless schema[:properties][attribute.to_sym]

              case validator
              when ActiveModel::Validations::PresenceValidator
                schema[:required] << attribute.to_sym unless schema[:required].include?(attribute.to_sym)
              when ActiveModel::Validations::LengthValidator
                if validator.options[:minimum]
                  schema[:properties][attribute.to_sym][:min_length] = validator.options[:minimum]
                end
                if validator.options[:maximum]
                  schema[:properties][attribute.to_sym][:max_length] = validator.options[:maximum]
                end
              when ActiveModel::Validations::NumericalityValidator
                if validator.options[:greater_than]
                  schema[:properties][attribute.to_sym][:exclusive_minimum] = validator.options[:greater_than]
                end
                if validator.options[:less_than]
                  schema[:properties][attribute.to_sym][:exclusive_maximum] = validator.options[:less_than]
                end
                if validator.options[:greater_than_or_equal_to]
                  schema[:properties][attribute.to_sym][:minimum] = validator.options[:greater_than_or_equal_to]
                end
                if validator.options[:less_than_or_equal_to]
                  schema[:properties][attribute.to_sym][:maximum] = validator.options[:less_than_or_equal_to]
                end
              when ActiveModel::Validations::InclusionValidator
                if validator.options[:in]
                  schema[:properties][attribute.to_sym][:enum] = validator.options[:in]
                end
              when ActiveModel::Validations::FormatValidator
                if validator.options[:with] == URI::MailTo::EMAIL_REGEXP
                  schema[:properties][attribute.to_sym][:format] = "email"
                elsif validator.options[:with]
                  schema[:properties][attribute.to_sym][:pattern] = validator.options[:with].source
                end
              end
            end
          end

          schema
        end
      end
    end

    # Generates a JSON string representation of a model's schema.
    #
    # This is an instance method that can be used to generate schema views
    # for individual model instances, though it operates on the class level.
    #
    # @param model_class [Class] The model class to generate a schema for
    # @param options [Hash] Schema generation options (see {ActiveRecordClassMethods#to_json_schema})
    #
    # @return [String] JSON string representation of the schema
    #
    # @deprecated This method may be removed in future versions. Use the class method `to_json_schema` instead.
    def generate_schema_view(model_class, options = {})
      schema = ActiveAgent::SchemaGenerator::Builder.json_schema_from_model(model_class, options)
      schema.to_json
    end
  end
end
