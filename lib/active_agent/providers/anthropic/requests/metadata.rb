# frozen_string_literal: true

require_relative "../../common/_base_model"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        # Metadata about the request
        class Metadata < Common::BaseModel
          attribute :user_id, :string

          validates :user_id, length: { maximum: 256 }, allow_nil: true
        end
      end
    end
  end
end
