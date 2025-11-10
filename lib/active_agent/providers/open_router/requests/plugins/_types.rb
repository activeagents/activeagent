# frozen_string_literal: true

require_relative "pdf_config"

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Plugins
          # Type for PdfConfig
          class PdfConfigType < ActiveModel::Type::Value
            def cast(value)
              case value
              when PdfConfig
                value
              when Hash
                PdfConfig.new(**value.deep_symbolize_keys)
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to PdfConfig"
              end
            end

            def serialize(value)
              case value
              when PdfConfig
                value.serialize
              when Hash
                value
              when nil
                nil
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end

            def deserialize(value)
              cast(value)
            end
          end
        end
      end
    end
  end
end
