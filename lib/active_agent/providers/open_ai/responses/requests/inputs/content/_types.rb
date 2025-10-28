# frozen_string_literal: true

require_relative "base"
require_relative "input_audio"
require_relative "input_file"
require_relative "input_image"
require_relative "input_text"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            module Content
              # Type for handling content (string or array of content parts)
              class ContentsType < ActiveModel::Type::Value
                def initialize
                  super
                  @content_type = ContentType.new
                end

                def cast(value)
                  case value
                  when String
                    # Plain text string - keep as string
                    value
                  when Array
                    # Array of content parts - cast each part
                    value.map { |part| @content_type.cast(part) }
                  when nil
                    nil
                  else
                    raise ArgumentError, "Cannot cast #{value.class} to Contents (expected String, Array, or nil)"
                  end
                end

                def serialize(value)
                  case value
                  when String
                    value
                  when Array
                    value.map { |part| @content_type.serialize(part) }
                  when nil
                    nil
                  else
                    raise ArgumentError, "Cannot serialize #{value.class} as Contents"
                  end
                end

                def deserialize(value)
                  cast(value)
                end
              end

              # Type for individual content items
              class ContentType < ActiveModel::Type::Value
                def cast(value)
                  case value
                  when Base
                    value
                  when Hash
                    hash = value.deep_symbolize_keys
                    type = hash[:type]&.to_sym

                    case type
                    when :input_text, :output_text
                      InputText.new(**hash.except(:annotations, :logprobs, :type))
                    when :input_image
                      InputImage.new(**hash)
                    when :input_file
                      InputFile.new(**hash)
                    when nil
                      # When type is nil, check for specific content keys to infer type
                      if hash.key?(:text)
                        InputText.new(**hash)
                      elsif hash.key?(:image)
                        InputImage.new(**hash.merge(image_url: hash.delete(:image)))
                      elsif hash.key?(:document)
                        cast_document_to_file(hash)
                      else
                        raise ArgumentError, "Cannot determine content type from hash keys: #{hash.keys.inspect}"
                      end
                    else
                      raise ArgumentError, "Unknown content type: #{type.inspect}"
                    end
                  when String
                    # Plain text string becomes input_text
                    InputText.new(text: value)
                  when nil
                    nil
                  else
                    raise ArgumentError, "Cannot cast #{value.class} to Content (expected Base, Hash, String, or nil)"
                  end
                end

                def serialize(value)
                  case value
                  when Base
                    value.serialize
                  when Hash
                    value
                  when String
                    { type: "input_text", text: value }
                  when nil
                    nil
                  else
                    raise ArgumentError, "Cannot serialize #{value.class} as Content"
                  end
                end

                def deserialize(value)
                  cast(value)
                end

                private

                def cast_document_to_file(hash)
                  document_value = hash.delete(:document)

                  case document_value
                  when String
                    if uri?(document_value)
                      # It's a URI/URL (http/https)
                      InputFile.new(**hash.merge(file_url: document_value))
                    elsif data_uri?(document_value)
                      # It's a data URI (e.g., data:application/pdf;base64,...)
                      # NOTE: While the OpenAI docs say filename is optional, it is required with base64 format
                      media_type, _data = parse_data_uri(document_value)
                      filename = generate_filename_from_media_type(media_type)
                      InputFile.new(**hash.merge(file_data: document_value, filename: filename))
                    else
                      raise ArgumentError, "Cannot determine source type for document value: #{document_value.inspect}"
                    end
                  else
                    raise ArgumentError, "Expected String for document key, got #{document_value.class}"
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

                def generate_filename_from_media_type(media_type)
                  # Map common media types to file extensions
                  extension = case media_type
                  when "application/pdf"
                    "pdf"
                  when "application/msword"
                    "doc"
                  when "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                    "docx"
                  when "application/vnd.ms-excel"
                    "xls"
                  when "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                    "xlsx"
                  when "application/vnd.ms-powerpoint"
                    "ppt"
                  when "application/vnd.openxmlformats-officedocument.presentationml.presentation"
                    "pptx"
                  when "text/plain"
                    "txt"
                  when "text/csv"
                    "csv"
                  when "text/html"
                    "html"
                  when "application/json"
                    "json"
                  when "application/xml", "text/xml"
                    "xml"
                  else
                    # Try to extract extension from media type (e.g., "application/xyz" -> "xyz")
                    media_type.split("/").last.split("+").first
                  end

                  "document.#{extension}"
                end
              end
            end
          end
        end
      end
    end
  end
end
