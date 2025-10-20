# frozen_string_literal: true

require_relative "base"
require_relative "document_base64"
require_relative "document_file"
require_relative "document_text"
require_relative "document_url"
require_relative "image_base64"
require_relative "image_file"
require_relative "image_url"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Content
          module Sources
            # Type for source objects (image/document sources)
            class SourceType < ActiveModel::Type::Value
              def cast(value)
                case value
                when Base
                  # Already a Source object, return as-is
                  value
                when Hash
                  # Symbolize keys once for consistent lookups
                  hash = value.symbolize_keys
                  type = hash[:type]&.to_s

                  case type
                  when "base64"
                    # Determine if it's image or document based on media_type or context
                    media_type = hash[:media_type]&.to_s
                    if media_type&.start_with?("image/")
                      ImageBase64.new(**hash)
                    else
                      DocumentBase64.new(**hash)
                    end
                  when "url"
                    # Could be either - default to image for now
                    # Callers can be more specific by passing the right class
                    ImageURL.new(**hash)
                  when "file"
                    # Could be either - default to image for now
                    ImageFile.new(**hash)
                  when "text"
                    DocumentText.new(**hash)
                  when nil
                    # No type specified - try to infer
                    infer_source_from_hash(hash)
                  else
                    raise ArgumentError, "Unknown source type: #{type}"
                  end
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Source"
                end
              end

              def serialize(value)
                case value
                when Base
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

              private

              def infer_source_from_hash(hash)
                if hash.key?(:image)
                  # Handle image key - detect URI or base64 data URI
                  cast_image_source(hash[:image], hash)
                elsif hash.key?(:document)
                  # Handle document key - detect URI or base64 data URI
                  cast_document_source(hash[:document], hash)
                elsif hash.key?(:data) && hash.key?(:media_type)
                  media_type = hash[:media_type]&.to_s
                  if media_type&.start_with?("image/")
                    ImageBase64.new(**hash.merge(type: "base64"))
                  else
                    DocumentBase64.new(**hash.merge(type: "base64"))
                  end
                elsif hash.key?(:url)
                  ImageURL.new(**hash.merge(type: "url"))
                elsif hash.key?(:file_id)
                  ImageFile.new(**hash.merge(type: "file"))
                elsif hash.key?(:text)
                  DocumentText.new(**hash.merge(type: "text"))
                else
                  raise ArgumentError, "Cannot cast hash without type to Source: #{hash.inspect}"
                end
              end

              def cast_image_source(image_value, original_hash)
                case image_value
                when String
                  if uri?(image_value)
                    # It's a URI/URL
                    ImageURL.new(type: "url", url: image_value)
                  elsif data_uri?(image_value)
                    # It's a data URI (e.g., data:image/jpeg;base64,...)
                    media_type, data = parse_data_uri(image_value)
                    ImageBase64.new(type: "base64", media_type: media_type, data: data)
                  else
                    raise ArgumentError, "Cannot determine source type for image value: #{image_value.inspect}"
                  end
                else
                  raise ArgumentError, "Expected String for image key, got #{image_value.class}"
                end
              end

              def cast_document_source(file_value, original_hash)
                case file_value
                when String
                  if uri?(file_value)
                    # It's a URI/URL
                    DocumentURL.new(type: "url", url: file_value)
                  elsif data_uri?(file_value)
                    # It's a data URI (e.g., data:application/pdf;base64,...)
                    media_type, data = parse_data_uri(file_value)
                    DocumentBase64.new(type: "base64", media_type: media_type, data: data)
                  else
                    raise ArgumentError, "Cannot determine source type for file value: #{file_value.inspect}"
                  end
                else
                  raise ArgumentError, "Expected String for file key, got #{file_value.class}"
                end
              end

              def uri?(value)
                # Check if it looks like a URI (http://, https://, etc.)
                value.match?(%r{\A(https?)://}i)
              end

              def data_uri?(value)
                # Check if it's a data URI (data:...)
                value.match?(/\Adata:/i)
              end

              def parse_data_uri(data_uri)
                # Parse data URI format: data:mime/type;base64,encoded_data
                match = data_uri.match(/\Adata:([^;,]+)(;base64)?,(.+)\z/i)
                raise ArgumentError, "Invalid data URI format: #{data_uri[0..50]}..." unless match

                media_type = match[1]
                is_base64 = !match[2].nil?
                data = match[3]

                unless is_base64
                  raise ArgumentError, "Only base64-encoded data URIs are supported: #{data_uri[0..50]}..."
                end

                [ media_type, data ]
              end
            end
          end
        end
      end
    end
  end
end
