# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        class ResponseFormat < Common::Options
          attribute :type, :string

          validates :type, inclusion: { in: %w[json_object] }, allow_nil: true
        end
      end
    end
  end
end
