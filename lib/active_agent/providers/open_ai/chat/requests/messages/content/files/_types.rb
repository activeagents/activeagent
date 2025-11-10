# frozen_string_literal: true

require_relative "details"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            module Content
              module Files
                # Type for the nested file object
                class DetailsType < ActiveModel::Type::Value
                  def cast(value)
                    case value
                    when Details
                      value
                    when Hash
                      Details.new(**value.deep_symbolize_keys)
                    when String
                      if value.start_with?("data:")
                        Details.new(file_data: value)
                      elsif value.match?(%r{\Ahttps?://})
                        raise ArgumentError, "HTTP/S URLs are not supported. Use a base64 data instead"
                      else
                        Details.new(file_data: value)
                      end
                    when nil
                      nil
                    else
                      raise ArgumentError, "Cannot cast #{value.class} to File::Details"
                    end
                  end

                  def serialize(value)
                    case value
                    when Details
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
    end
  end
end
