# frozen_string_literal: true

require_relative "base"
require_relative "text"
require_relative "image"
require_relative "audio"
require_relative "file"
require_relative "refusal"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
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
                    # Plain text string - convert to array with single text content
                    [ Text.new(text: value) ]
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
                    array = value.map { |part| @content_type.serialize(part) }

                    if array in [ { type: "text", text: String } ]
                      array.first[:text]
                    else
                      array
                    end
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
                    when :text
                      Text.new(**hash)
                    when :image_url
                      Image.new(**hash)
                    when :input_audio
                      Audio.new(**hash)
                    when :file
                      File.new(**hash)
                    when :refusal
                      Refusal.new(**hash)
                    when nil
                      # When type is nil, check for specific content keys to infer type
                      if hash.key?(:text)
                        Text.new(**hash)
                      elsif hash.key?(:image)
                        Image.new(**hash.merge(image_url: hash.delete(:image)))
                      elsif hash.key?(:document)
                        File.new(**hash.merge(file: hash.delete(:document)))
                      else
                        raise ArgumentError, "Cannot determine content type from hash keys: #{hash.keys.inspect}"
                      end
                    else
                      raise ArgumentError, "Unknown content type: #{type.inspect}"
                    end
                  when String
                    # Plain text string becomes text content
                    Text.new(text: value)
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
                    { type: "text", text: value }
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
