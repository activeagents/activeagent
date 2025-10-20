# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Content
          module Sources
            # Text document source
            class DocumentText < Base
              attribute :type, :string, as: "text"
              attribute :text, :string
              attribute :media_type, :string

              validates :text, presence: true
              validates :media_type, presence: true
            end
          end
        end
      end
    end
  end
end
