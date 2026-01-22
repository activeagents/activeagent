# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Common
      # BaseModel provides a foundation for structured data models with compressed serialization support.
      #
      # This class extends ActiveModel functionality to provide:
      # - Attribute definition with default values
      # - Compressed hash serialization (excludes default values)
      # - Required attribute tracking
      # - Deep compaction of nested structures
      #
      # == Example
      #
      #   class Message < BaseModel
      #     attribute :role, :string, as: "user"
      #     attribute :type, :string, fallback: "plain/text"
      #     attribute :content, :string
      #   end
      #
      #   message = Message.new(content: "Hello")
      #   message.to_h      #=> { role: "user", type: "plain/text", content: "Hello" }
      #   message.serialize #=> { role: "user", type: "plain/text", content: "Hello" }
      class BaseModel
        include ActiveModel::Model
        include ActiveModel::Attributes

        # Returns the set of required attribute names that must be included in compressed output.
        #
        # Required attributes are those defined with the +as+ option, which establishes
        # a default value that should always be serialized.
        #
        # @return [Set<String>] set of required attribute names
        def self.required_attributes
          @required_attributes ||= Set.new
        end

        # Ensures subclasses get their own required_attributes set.
        #
        # @param subclass [Class] the inheriting class
        # @return [void]
        def self.inherited(subclass)
          super
          subclass.instance_variable_set(:@required_attributes, required_attributes.dup)
        end

        # Defines an attribute on the model with special handling for default values.
        #
        # @param name [Symbol, String] the name of the attribute
        # @param type [Class, nil] the type of the attribute (optional)
        # @param options [Hash] additional options for the attribute
        # @option options [Object] :as A default value that makes the attribute read-only.
        #   When set, attempts to assign a different value will raise an ArgumentError.
        #   This attribute will be included in the compressed hash representation.
        # @option options [Object] :fallback A default value for the attribute.
        #   This attribute will be included in the compressed hash representation.
        #
        # @raise [ArgumentError] if attempting to set a value different from the :as default
        #
        # @example Define a read-only attribute with a default value
        #   attribute :role, :string, as: "user"
        #
        # @example Define an attribute with a fallback value
        #   attribute :temperature, :float, fallback: 0.7
        #
        # @example Define a regular attribute
        #   attribute :messages, :array
        def self.attribute(name, type = nil, **options)
          if options.key?(:as)
            default_value = options.delete(:as)
            super(name, type, default: default_value, **options)

            # Track this attribute as required (must be included in compressed hash)
            required_attributes << name.to_s

            define_method("#{name}=") do |value|
              normalized_value   = value.is_a?(String)         ? value.to_sym         : value
              normalized_default = default_value.is_a?(String) ? default_value.to_sym : default_value

              next if normalized_value == normalized_default

              raise ArgumentError, "Cannot set '#{name}' attribute (read-only with default value)"
            end
          elsif options.key?(:fallback)
            default_value = options.delete(:fallback)
            super(name, type, default: default_value, **options)

            # Track this attribute as required (must be included in compressed hash)
            required_attributes << name.to_s
          else
            super(name, type, **options)
          end
        end

        # Delegates attribute accessors to another object.
        #
        # Creates getter and setter methods that forward to the specified target object.
        # If the target is nil when setting, an empty hash is initialized.
        #
        # @param attributes [Array<Symbol>] attribute names to delegate
        # @param to [Symbol] the target method/attribute name
        #
        # @example
        #   delegate_attributes :temperature, :max_tokens, to: :options
        def self.delegate_attributes(*attributes, to:)
          attributes.each do |attribute|
            define_method(attribute) do
              public_send(to)&.public_send(attribute)
            end

            define_method("#{attribute}=") do |value|
              public_send("#{to}=", {}) if public_send(to).nil?

              public_send(to).public_send("#{attribute}=", value)
            end
          end
        end

        # Drops specified attributes by defining no-op setters.
        #
        # This is useful when converting between providers that support different attributes
        # or when dropping attributes during message response to request construction.
        # The attributes can still be read if defined elsewhere, but setting them has no effect.
        #
        # @param attributes [Array<Symbol>] attribute names to drop
        # @return [void]
        #
        # @example
        #   drop_attributes :metadata, :extra_info
        def self.drop_attributes(*attributes)
          attributes.each do |attribute|
            define_method("#{attribute}=") do |value|
              # No-Op: Drop the value
            end
          end
        end

        # Returns all attribute keys including aliases.
        #
        # Combines both the main attribute type keys and any attribute aliases,
        # ensuring all possible attribute names are represented as symbols.
        #
        # @return [Array<Symbol>] array of all attribute keys
        def self.keys
          (attribute_types.keys.map(&:to_sym) | attribute_aliases.keys.map(&:to_sym))
        end

        # Initializes a new instance with the given attributes.
        #
        # Attributes can be provided as a hash. Hash keys are sorted to prioritize nested
        # objects during initialization for backwards compatibility. A special internal key
        # `__default_values` can be passed to get an instance with only default values
        # without any overrides.
        #
        # @param kwargs [Hash] attributes to initialize the instance with
        # @return [BaseModel] the initialized instance
        #
        # @example
        #   Message.new(role: "user", content: "Hello")
        def initialize(kwargs = {})
          # To allow us to get a list of attribute defaults without initialized overrides
          return super(nil) if kwargs.key?(:'__default_values')

          # Backwards Compatibility: This sorts object construction to the top to protect the assignment
          #   of backward compatibility assignments.
          kwargs = kwargs.sort_by { |k, v| v.is_a?(Hash) ? 0 : 1 }.to_h if kwargs.is_a?(Hash)

          super(kwargs)
        end

        # Merges the given attributes into the current instance.
        #
        # Only attributes with corresponding setter methods are updated.
        # Keys are symbolized before merging.
        #
        # @param kwargs [Hash] attribute keyword arguments to merge
        # @return [BaseModel] self for method chaining
        def merge!(kwargs = {})
          kwargs.deep_symbolize_keys.each do |key, value|
            public_send("#{key}=", value) if respond_to?("#{key}=")
          end

          self
        end

        # Recursively removes nil values and empty collections from a hash.
        #
        # Nested hashes and arrays are processed recursively. Empty hashes and
        # arrays after compaction are also removed.
        #
        # @param kwargs [Hash] hash to compact
        # @return [Hash] compacted hash with nil values and empty collections removed
        #
        # @example
        #   deep_compact({ a: 1, b: nil, c: { d: nil, e: 2 } })
        #   #=> { a: 1, c: { e: 2 } }
        def deep_compact(kwargs = {})
          kwargs.each_with_object({}) do |(key, value), result|
            compacted_value = case value
            when Hash
              deep_compacted = deep_compact(value)
              deep_compacted unless deep_compacted.empty?
            when Array
              compacted_array = value.map { |v| v.is_a?(Hash) ? deep_compact(v) : v }.compact
              compacted_array unless compacted_array.empty?
            else
              value
            end

            result[key] = compacted_value unless compacted_value.nil?
          end
        end

        # Converts the model to a hash representation.
        #
        # Recursively converts nested BaseModel instances and arrays to hashes.
        # Nil values and empty collections are removed via deep_compact.
        #
        # @return [Hash] hash representation of all attributes
        #
        # @example
        #   message.to_hash
        #   #=> { role: "user", content: "Hello", metadata: { id: 1 } }
        def to_hash
          deep_compact(attribute_names.each_with_object({}) do |name, hash|
            value = public_send(name)

            hash[name.to_sym] = case value
            when BaseModel then value.to_hash
            when Array     then value.map { _1.is_a?(BaseModel) ? _1.to_hash : _1 }
            else
              value
            end
          end)
        end

        # Alias for {#to_hash}.
        #
        # @return [Hash] hash representation of all attributes
        # @see #to_hash
        def to_h = to_hash

        # Creates a deep duplicate of the model.
        #
        # Duplicates the model instance and recursively duplicates any array or hash attributes
        # to ensure complete independence from the original object.
        #
        # @return [BaseModel] deep duplicate of the model
        def deep_dup
          dup.tap do |duplicated|
            attribute_names.each do |name|
              value = public_send(name)
              next if value.nil?

              duplicated.public_send("#{name}=", case value
              when Array
                value.map { |v| v.respond_to?(:deep_dup) ? v.deep_dup : v.dup rescue v }
              when Hash
                value.deep_dup
              when BaseModel
                value.deep_dup
              else
                value.dup rescue value
              end)
            end
          end
        end

        # Serializes the model using attribute type serializers.
        #
        # Iterates through each attribute and uses its ActiveModel::Type serializer
        # to convert the value to its serialized form. Only non-default values are included,
        # except for required attributes (those defined with `:as` or `:fallback` options).
        # This provides a compressed serialization that respects custom type logic.
        #
        # @return [Hash] serialized representation with non-default and required attributes
        #
        # @example
        #   message = Message.new(role: "user", content: "Hello")
        #   message.serialize  #=> { role: "user", content: "Hello" }
        def serialize
          default_values = self.class.new(__default_values: true).attributes
          required_attrs = self.class.required_attributes

          deep_compact(attribute_names.each_with_object({}) do |name, hash|
            value = public_send(name)

            # Always include required attributes (those defined with 'as' option)
            # or attributes that differ from their default value
            next if value == default_values[name] && !required_attrs.include?(name)

            # Use the attribute's type serializer
            attr_type = self.class.attribute_types[name]
            hash[name.to_sym] = attr_type.serialize(value)
          end)
        end

        # Returns a string representation for inspection.
        #
        # Provides a readable view of the model showing the class name and non-default attributes
        # in a format similar to standard Ruby object inspection.
        #
        # @return [String] formatted string representation
        # @see #serialize
        #
        # @example
        #   message = Message.new(role: "user", content: "Hello")
        #   message.inspect
        #   #=> "#<Message role: \"user\", content: \"Hello\">"
        def inspect
          attrs = JSON.pretty_generate(serialize, {
            space: " ",
            indent: "  ",
            object_nl: "\n",
            array_nl: "\n"
          }).lines.drop(1).join.chomp.sub(/\}\z/, "").strip

          return "#<#{self.class.name}>" if attrs.empty?

          "#<#{self.class.name} {\n  #{attrs}\n}>"
        end

        # @see #inspect
        alias_method :to_s, :inspect

        # Compares two models based on their serialized representations.
        #
        # Uses the serialized hash to compare models, allowing for sorting and equality
        # comparisons based on attribute values rather than object identity.
        #
        # @param other [BaseModel] the model to compare against
        # @return [Integer, nil] -1, 0, 1, or nil if not comparable
        #
        # @example
        #   model1 = Message.new(content: "A")
        #   model2 = Message.new(content: "B")
        #   model1 <=> model2  #=> -1
        def <=>(other)
          serialize <=> other&.serialize
        end

        # Compares equality based on serialized representation.
        #
        # Two models are equal if their serialized hashes are equal, regardless
        # of object identity. This allows value-based equality comparisons.
        #
        # @param other [BaseModel] the model to compare against
        # @return [Boolean]
        #
        # @example
        #   model1 = Message.new(content: "Hello")
        #   model2 = Message.new(content: "Hello")
        #   model1 == model2  #=> true
      def ==(other)
        serialize == other&.serialize
      end
    end

    # Zeitwerk expects this file to define ActiveAgent::Providers::Common::Model
    # based on its path. Provide an alias so autoloading succeeds while keeping
    # the BaseModel name used throughout the codebase.
    Model = BaseModel
  end
end
end
