# frozen_string_literal: true

require_relative "../_base_model"

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
