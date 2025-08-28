# frozen_string_literal: true

module ActiveAgent
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

    module ActiveRecordClassMethods
      def to_json_schema(options = {})
        ActiveAgent::SchemaGenerator::Builder.json_schema_from_model(self, options)
      end
    end

    module ActiveModelClassMethods
      def to_json_schema(options = {})
        ActiveAgent::SchemaGenerator::Builder.json_schema_from_model(self, options)
      end
    end

    class Builder
      def self.json_schema_from_model(model_class, options = {})
        schema = {
          type: "object",
          properties: {},
          required: [],
          additionalProperties: options.fetch(:additional_properties, false)
        }

        if defined?(ActiveRecord::Base) && model_class < ActiveRecord::Base
          build_activerecord_schema(model_class, schema, options)
        elsif defined?(ActiveModel::Model) && model_class.include?(ActiveModel::Model)
          build_activemodel_schema(model_class, schema, options)
        else
          raise ArgumentError, "Model must be an ActiveRecord or ActiveModel class"
        end

        if options[:strict]
          # OpenAI strict mode requires all properties to be in the required array
          # So we add all properties to required if strict mode is enabled
          schema[:required] = schema[:properties].keys.map(&:to_s).sort

          {
            name: options[:name] || model_class.name.underscore,
            schema: schema,
            strict: true
          }
        else
          schema
        end
      end

      class << self
        private

        def build_activerecord_schema(model_class, schema, options)
          model_class.columns.each do |column|
            next if options[:exclude]&.include?(column.name.to_sym)
            next if column.name == "id" && !options[:include_id]

            property = build_property_from_column(column)
            schema[:properties][column.name] = property

            if !column.null && column.name != "id"
              schema[:required] << column.name
            end
          end

          if model_class.reflect_on_all_associations.any?
            add_associations_to_schema(model_class, schema, options)
          end

          if model_class.respond_to?(:validators)
            add_validations_to_schema(model_class, schema, options)
          end
      end

        def build_activemodel_schema(model_class, schema, options)
        if model_class.respond_to?(:attribute_types)
          model_class.attribute_types.each do |name, type|
            next if options[:exclude]&.include?(name.to_sym)

            property = build_property_from_type(type)
            schema[:properties][name] = property
          end
        end

        if model_class.respond_to?(:validators)
          add_validations_to_schema(model_class, schema, options)
        end
      end

        def build_property_from_column(column)
        property = {
          type: map_sql_type_to_json_type(column.type),
          description: "#{column.name.humanize} field"
        }

        case column.type
        when :string, :text
          if column.limit
            property[:maxLength] = column.limit
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

        def add_associations_to_schema(model_class, schema, options)
        return unless options[:include_associations]

        schema[:$defs] ||= {}

        model_class.reflect_on_all_associations.each do |association|
          next if options[:exclude_associations]&.include?(association.name)

          case association.macro
          when :has_many, :has_and_belongs_to_many
            schema[:properties][association.name.to_s] = {
              type: "array",
              items: { "$ref": "#/$defs/#{association.name.to_s.singularize}" }
            }
            if options[:nested_associations]
              nested_schema = json_schema_from_model(
                association.klass,
                options.merge(include_associations: false)
              )
              schema[:$defs][association.name.to_s.singularize] = nested_schema
            end
          when :has_one, :belongs_to
            schema[:properties][association.name.to_s] = {
              "$ref": "#/$defs/#{association.name}"
            }
            if options[:nested_associations]
              nested_schema = json_schema_from_model(
                association.klass,
                options.merge(include_associations: false)
              )
              schema[:$defs][association.name.to_s] = nested_schema
            end
          end
        end
      end

        def add_validations_to_schema(model_class, schema, options)
        model_class.validators.each do |validator|
          validator.attributes.each do |attribute|
            next unless schema[:properties][attribute.to_s]

            case validator
            when ActiveModel::Validations::PresenceValidator
              schema[:required] << attribute.to_s unless schema[:required].include?(attribute.to_s)
            when ActiveModel::Validations::LengthValidator
              if validator.options[:minimum]
                schema[:properties][attribute.to_s][:minLength] = validator.options[:minimum]
              end
              if validator.options[:maximum]
                schema[:properties][attribute.to_s][:maxLength] = validator.options[:maximum]
              end
            when ActiveModel::Validations::NumericalityValidator
              if validator.options[:greater_than]
                schema[:properties][attribute.to_s][:exclusiveMinimum] = validator.options[:greater_than]
              end
              if validator.options[:less_than]
                schema[:properties][attribute.to_s][:exclusiveMaximum] = validator.options[:less_than]
              end
              if validator.options[:greater_than_or_equal_to]
                schema[:properties][attribute.to_s][:minimum] = validator.options[:greater_than_or_equal_to]
              end
              if validator.options[:less_than_or_equal_to]
                schema[:properties][attribute.to_s][:maximum] = validator.options[:less_than_or_equal_to]
              end
            when ActiveModel::Validations::InclusionValidator
              if validator.options[:in]
                schema[:properties][attribute.to_s][:enum] = validator.options[:in]
              end
            when ActiveModel::Validations::FormatValidator
              if validator.options[:with] == URI::MailTo::EMAIL_REGEXP
                schema[:properties][attribute.to_s][:format] = "email"
              elsif validator.options[:with]
                schema[:properties][attribute.to_s][:pattern] = validator.options[:with].source
              end
            end
          end
        end
      end
      end
    end

    def generate_schema_view(model_class, options = {})
      schema = ActiveAgent::SchemaGenerator::Builder.json_schema_from_model(model_class, options)
      schema.to_json
    end
  end
end
