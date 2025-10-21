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
                        InputFile.new(**hash.merge(file_url: hash.delete(:document)))
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
              end
            end
          end
        end
      end
    end
  end
end
