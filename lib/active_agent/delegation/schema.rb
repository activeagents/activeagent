# frozen_string_literal: true

module ActiveAgent
  module Delegation
    # Declarative JSON Schema for a delegated agent's inputs and outputs.
    #
    # A delegation is only as good as its contract: the calling model needs to
    # know exactly what a sub-agent accepts, and the calling *agent* needs to
    # know what shape comes back. Schema builds both from a small DSL, from a
    # plain JSON Schema hash, or from any class that responds to
    # +to_json_schema+ (see {ActiveAgent::SchemaGenerator}).
    #
    # @example DSL
    #   Schema.build do
    #     string  :text, required: true, description: "Document to summarize"
    #     integer :max_points, description: "How many bullets to return"
    #     array   :tags, of: :string, description: "Topic tags"
    #   end
    #
    # @example Plain JSON Schema
    #   Schema.build(type: "object", properties: { text: { type: "string" } }, required: [ "text" ])
    #
    # @example ActiveModel / ActiveRecord
    #   Schema.build(ContactForm) # ContactForm includes ActiveAgent::SchemaGenerator
    class Schema
      # Scalar types that get a one-line DSL helper.
      SCALAR_TYPES = %i[string integer number boolean].freeze

      class << self
        # Coerces any supported schema source into a Schema.
        #
        # @param source [Schema, Hash, Class, nil] existing schema, raw JSON Schema,
        #   or a class responding to +to_json_schema+
        # @yield DSL block (evaluated against a new Schema, or yielded when arity is 1)
        # @return [Schema]
        # @raise [ArgumentError] when the source cannot be interpreted
        def build(source = nil, &block)
          schema =
            case source
            when Schema then source
            when Hash   then from_hash(source)
            when nil    then new
            else
              if source.respond_to?(:to_json_schema)
                from_hash(source.to_json_schema)
              else
                raise ArgumentError, "Cannot build a delegation schema from #{source.inspect}. " \
                  "Pass a Hash, a class responding to #to_json_schema, or use the block DSL."
              end
            end

          if block
            block.arity == 1 ? block.call(schema) : schema.instance_eval(&block)
          end

          schema
        end

        # @param hash [Hash] JSON Schema object
        # @return [Schema]
        def from_hash(hash)
          hash = hash.deep_symbolize_keys

          new.tap do |schema|
            (hash[:properties] || {}).each { |name, definition| schema.property(name, definition) }
            schema.required(*Array(hash[:required]))
            schema.additional_properties(hash.fetch(:additionalProperties, hash.fetch(:additional_properties, false)))
          end
        end
      end

      def initialize
        @properties           = {}
        @required             = []
        @additional_properties = false
      end

      # @return [Boolean] true when nothing has been declared
      def empty?
        @properties.empty?
      end

      # Declares a property from an already-built JSON Schema fragment.
      #
      # @param name [Symbol, String]
      # @param definition [Hash] JSON Schema fragment (e.g. +{ type: "string" }+)
      # @return [void]
      def property(name, definition)
        @properties[name.to_sym] = definition.deep_symbolize_keys
      end

      # Declares a property.
      #
      # @param name [Symbol, String]
      # @param type [Symbol, String] JSON Schema type
      # @param required [Boolean] whether the calling model must supply it
      # @param description [String, nil] shown to the calling model — write it for a reader who
      #   has never seen your code
      # @param options [Hash] any other JSON Schema keyword (+enum+, +format+, +minimum+, ...)
      # @yield nested DSL for object properties
      # @return [void]
      def param(name, type = :string, required: false, description: nil, **options, &block)
        definition = { type: type.to_s, description: description }.compact.merge(options)

        if block
          nested = self.class.build(&block)
          definition = definition.merge(nested.to_json_schema.except(:type))
          definition[:type] = "object"
        end

        property(name, definition)
        self.required(name) if required
      end

      SCALAR_TYPES.each do |type|
        define_method(type) do |name, **options|
          param(name, type, **options)
        end
      end

      # Declares an object property.
      #
      # @param name [Symbol, String]
      # @yield nested DSL
      def object(name, **options, &block)
        param(name, :object, **options, &block)
      end

      # Declares an array property.
      #
      # @param name [Symbol, String]
      # @param of [Symbol, String, Hash, nil] item type, or a JSON Schema fragment for items
      # @yield nested DSL describing an object item type
      def array(name, of: nil, **options, &block)
        items =
          if block
            self.class.build(&block).to_json_schema
          elsif of.is_a?(Hash)
            of.deep_symbolize_keys
          elsif of
            { type: of.to_s }
          end

        param(name, :array, **options.merge({ items: items }.compact))
      end

      # Marks properties as required.
      #
      # @param names [Array<Symbol, String>]
      # @return [Array<Symbol>]
      def required(*names)
        names.flatten.each { |name| @required |= [ name.to_sym ] }
        @required
      end

      # @param value [Boolean]
      def additional_properties(value = true)
        @additional_properties = value
      end

      # @return [Array<Symbol>] declared property names
      def keys
        @properties.keys
      end

      # @return [Array<Symbol>] required property names
      def required_keys
        @required.dup
      end

      # @return [Hash] JSON Schema object
      #
      # @note Deep-duplicated: providers normalize tool definitions in place,
      #   and a schema is shared by every generation that exposes it.
      def to_json_schema
        {
          type: "object",
          properties: @properties.deep_dup,
          required: @required.map(&:to_s),
          additionalProperties: @additional_properties
        }
      end
      alias_method :to_h, :to_json_schema

      # JSON Schema for a +response_format+ payload.
      #
      # ActiveAgent camelizes response-format schema *keys* on the way to the
      # provider, but the +required+ array holds string *values* — so they are
      # camelized here to keep the emitted schema internally consistent.
      # {Assistant#parsed_json} underscores the keys again on the way back, so
      # agent code only ever sees snake_case.
      #
      # @param name [String] schema name reported to the provider
      # @param strict [Boolean]
      # @return [Hash]
      def to_response_format(name:, strict: true)
        schema = to_json_schema
        schema[:required] = schema[:required].map { |key| key.camelize(:lower) }

        { name: name, schema: schema, strict: strict }
      end

      # Validates a parsed payload against the declared required properties.
      #
      # This is a deliberately shallow check: it catches the failure that
      # actually happens in practice (a model omitting a required key) without
      # pulling a full JSON Schema validator into the gem's dependencies.
      #
      # @param payload [Hash, nil]
      # @return [Array<Symbol>] missing required keys
      def missing_keys(payload)
        return required_keys if payload.nil?
        return [] unless payload.is_a?(Hash)

        keys = payload.keys.map { |key| key.to_s.underscore.to_sym }
        required_keys.reject { |key| keys.include?(key) }
      end
    end
  end
end
