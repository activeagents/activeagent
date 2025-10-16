# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
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
      #     attribute :type, :string, default: "plain/text"
      #     attribute :content, :string
      #   end
      #
      #   message = Message.new(content: "Hello")
      #   message.to_h   #=> { role: "user", type: "plain/text", content: "Hello" }
      #   message.to_hc  #=> { role: "user", content: "Hello" }
      class BaseModel
        include ActiveModel::Model
        include ActiveModel::Attributes

        # Class-level tracking of attributes with 'as' option
        class << self
          # Returns the set of required attribute names that must be included in compressed output.
          #
          # Required attributes are those defined with the +as+ option, which establishes
          # a default value that should always be serialized.
          #
          # @return [Set<String>] set of required attribute names
          def required_attributes
            @required_attributes ||= Set.new
          end

          # Ensures subclasses get their own required_attributes set.
          #
          # @param subclass [Class] the inheriting class
          def inherited(subclass)
            super
            subclass.instance_variable_set(:@required_attributes, Set.new)
          end
        end

        # Defines an attribute with optional default value using the +as+ option.
        #
        # When the +as+ option is provided, the attribute becomes read-only with a fixed
        # default value and is marked as required for compressed serialization.
        #
        # @param name [Symbol] the attribute name
        # @param type [Symbol, nil] the attribute type
        # @param options [Hash] additional options
        # @option options [Object] :as default value (makes attribute read-only and required)
        #
        # @example Define a read-only attribute with default
        #   attribute :role, :string, as: "assistant"
        #
        # @example Define a regular attribute
        #   attribute :content, :string
        def self.attribute(name, type = nil, **options)
          if options.key?(:as)
            default_value = options.delete(:as)
            super(name, type, default: default_value, **options)

            # Track this attribute as required (must be included in compressed hash)
            required_attributes << name.to_s

            define_method("#{name}=") do |value|
              next if value == default_value
              raise ArgumentError, "Cannot set '#{name}' attribute (read-only with default value)"
            end
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

        # Initializes a new instance with the given attributes.
        #
        # Settings can be provided as a hash or keyword arguments. Hash keys are
        # sorted to prioritize nested objects during initialization for backwards compatibility.
        #
        # @param hash [Hash, nil] attribute hash
        # @param kwargs [Hash] attribute keyword arguments
        def initialize(hash = nil, **kwargs)
          settings = hash || kwargs
          # Backwards Compatibility: This sorts object construction to the top to protect the assignment
          #   of backward compatibility assignments.
          settings = settings.sort_by { |k, v| v.is_a?(Hash) ? 0 : 1 }.to_h if settings.is_a?(Hash)

          super(settings)
        end

        # Merges the given attributes into the current instance.
        #
        # Only attributes with corresponding setter methods are updated.
        #
        # @param hash [Hash, nil] attribute hash to merge
        # @param kwargs [Hash] attribute keyword arguments to merge
        # @return [BaseModel] self for method chaining
        def merge!(hash = nil, **kwargs)
          (hash || kwargs).deep_symbolize_keys.each do |key, value|
            public_send("#{key}=", value) if respond_to?("#{key}=")
          end

          self
        end

        # Recursively removes nil values and empty collections from a hash.
        #
        # Nested hashes and arrays are processed recursively. Empty hashes and
        # arrays after compaction are also removed.
        #
        # @param hash [Hash, nil] hash to compact
        # @param kwargs [Hash] hash as keyword arguments
        # @return [Hash] compacted hash
        #
        # @example
        #   deep_compact({ a: 1, b: nil, c: { d: nil, e: 2 } })
        #   #=> { a: 1, c: { e: 2 } }
        def deep_compact(hash = nil, **kwargs)
          (hash || kwargs).each_with_object({}) do |(key, value), result|
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
            when BaseModel then value.to_h
            when Array     then value.map { it.is_a?(BaseModel) ? it.to_h : it }
            else
              value
            end
          end)
        end
        alias_method :to_h, :to_hash

        # Converts the model to a compressed hash representation.
        #
        # Returns a deep compacted hash with default values removed to minimize payload size.
        # Attributes defined with the +as+ option are always included, even if they match
        # their default value, as they are considered required for the API schema.
        #
        # This is useful for API calls where defaults are implicit and don't need to be sent,
        # saving bandwidth and costs.
        #
        # @return [Hash] compressed hash with defaults removed (except required attributes)
        #
        # @example
        #   class Message < BaseModel
        #     attribute :role, :string, as: "user", default: "user"
        #     attribute :content, :string, default: ""
        #   end
        #
        #   message = Message.new(role: "user", content: "")
        #   message.to_hash_compressed
        #   #=> { role: "user" }  # content omitted (matches default), role included (required)
        def to_hash_compressed
          default_values = self.class.new.attributes
          required_attrs = self.class.required_attributes

          deep_compact(attribute_names.each_with_object({}) do |name, hash|
            value = public_send(name)

            # Always include required attributes (those defined with 'as' option)
            # or attributes that differ from their default value
            next if value == default_values[name] && !required_attrs.include?(name)

            hash[name.to_sym] = case value
            when BaseModel then value.to_hc
            when Array     then value.map { it.is_a?(BaseModel) ? it.to_hc : it }
            else
              value
            end
          end)
        end
        alias_method :to_hc, :to_hash_compressed

        # Returns a hash representation for inspection.
        #
        # @return [Hash] hash representation via to_h
        def inspect
          to_hc
        end
      end
    end
  end
end
