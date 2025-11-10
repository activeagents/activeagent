# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module TextFormats
            # JSON object format (older method)
            class JsonObject < Base
              attribute :type, :string, as: "json_object"
            end
          end
        end
      end
    end
  end
end
