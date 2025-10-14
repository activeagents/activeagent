# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module Common
      class BaseModel
        include ActiveModel::Model
        include ActiveModel::Attributes

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

        def initialize(hash = nil, **kwargs)
          settings = hash || kwargs
          # Backwards Compatibility: This sorts object construction to the top to protect the assignment
          #   of backward compatibility assignments.
          settings = settings.sort_by { |k, v| v.is_a?(Hash) ? 0 : 1 }.to_h if settings.is_a?(Hash)

          super(settings)
        end

        def merge!(hash = nil, **kwargs)
          (hash || kwargs).deep_symbolize_keys.each do |key, value|
            public_send("#{key}=", value) if respond_to?("#{key}=")
          end

          self
        end

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

        def to_hash
          deep_compact(attribute_names.each_with_object({}) do |name, hash|
            value = public_send(name)
            hash[name.to_sym] = value.is_a?(Options) ? value.to_h : value
          end)
        end
        alias_method :to_h, :to_hash

        # This returns a deep compacted hash with all the defaults removed, since the defaults are provided by the
        # API spec/schema we don't need to send them, saving on bandwidth/costs.
        def to_hash_compressed
          default_values = self.class.new.attributes

          deep_compact(attribute_names.each_with_object({}) do |name, hash|
            value = public_send(name)

            next if value == default_values[name]

            hash[name.to_sym] = value.is_a?(Options) ? value.to_h : value
          end)
        end
        alias_method :to_hc, :to_hash_compressed

        def inspect
          to_h
        end
      end
    end
  end
end
