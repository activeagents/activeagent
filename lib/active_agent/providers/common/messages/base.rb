# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Common
      module Messages
        class Base < Common::BaseModel
          attribute :role, :string

          validates :role, presence: true
        end
      end
    end
  end
end
