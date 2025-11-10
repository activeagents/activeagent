# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module TextFormats
            # Plain text format
            class Plain < Base
              attribute :type, :string, as: "text"
            end
          end
        end
      end
    end
  end
end
