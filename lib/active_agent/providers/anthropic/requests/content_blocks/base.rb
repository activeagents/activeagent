# frozen_string_literal: true

require_relative "../../../common/_base_model"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ContentBlocks
          # Base class for all content blocks
          class Base < Common::BaseModel
            attribute :type, :string

            validates :type, presence: true
          end
        end
      end
    end
  end
end
