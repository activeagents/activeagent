# frozen_string_literal: true

require "active_agent/providers/open_ai/chat/requests/messages/content/_types"
require_relative "file"

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Messages
          module Content
            # Type for handling content (string or array of content parts) in OpenRouter.
            #
            # Extends OpenAI's ContentsType to use OpenRouter's ContentType which
            # handles files differently (preserves data URI prefix).
            class ContentsType < OpenAI::Chat::Requests::Messages::Content::ContentsType
              def initialize
                super
                @content_type = ContentType.new
              end
            end

            # Type for individual content items in OpenRouter.
            #
            # Uses OpenRouter's File class for file content which preserves
            # the data URI prefix that OpenAI strips.
            class ContentType < ActiveModel::Type::Value
              def cast(value)
                case value
                when OpenAI::Chat::Requests::Messages::Content::Base
                  value
                when Hash
                  hash = value.deep_symbolize_keys
                  type = hash[:type]&.to_sym

                  case type
                  when :text
                    OpenAI::Chat::Requests::Messages::Content::Text.new(**hash)
                  when :image_url
                    OpenAI::Chat::Requests::Messages::Content::Image.new(**hash)
                  when :input_audio
                    OpenAI::Chat::Requests::Messages::Content::Audio.new(**hash)
                  when :file
                    # Use OpenRouter's File class instead of OpenAI's
                    File.new(**hash)
                  when :refusal
                    OpenAI::Chat::Requests::Messages::Content::Refusal.new(**hash)
                  when nil
                    # When type is nil, check for specific content keys to infer type
                    if hash.key?(:text)
                      OpenAI::Chat::Requests::Messages::Content::Text.new(**hash)
                    elsif hash.key?(:image)
                      OpenAI::Chat::Requests::Messages::Content::Image.new(**hash.merge(image_url: hash.delete(:image)))
                    elsif hash.key?(:document)
                      # Use OpenRouter's File class for document content
                      File.new(**hash.merge(file: hash.delete(:document)))
                    else
                      raise ArgumentError, "Cannot determine content type from hash keys: #{hash.keys.inspect}"
                    end
                  else
                    raise ArgumentError, "Unknown content type: #{type.inspect}"
                  end
                when String
                  # Plain text string becomes text content
                  OpenAI::Chat::Requests::Messages::Content::Text.new(text: value)
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Content (expected Base, Hash, String, or nil)"
                end
              end

              def serialize(value)
                case value
                when OpenAI::Chat::Requests::Messages::Content::Base
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
