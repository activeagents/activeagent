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
                    value
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
                    value
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
                    type = value[:type]&.to_s || value["type"]&.to_s

                    case type
                    when "input_text"
                      InputText.new(**value.symbolize_keys)
                    when "input_image"
                      InputImage.new(**value.symbolize_keys)
                    when "input_file"
                      InputFile.new(**value.symbolize_keys)
                    else
                      # Return hash as-is if type is unknown
                      value
                    end
                  when String
                    # Plain text string becomes input_text
                    InputText.new(text: value)
                  when nil
                    nil
                  else
                    value
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
                    value
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
