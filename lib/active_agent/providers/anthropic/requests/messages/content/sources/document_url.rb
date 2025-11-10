# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Content
          module Sources
            # URL-based document source
            class DocumentURL < Base
              attribute :type, :string, as: "url"
              attribute :url, :string

              validates :url, presence: true
            end
          end
        end
      end
    end
  end
end
