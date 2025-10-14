# frozen_string_literal: true

require_relative "_base_model"

module ActiveAgent
  module GenerationProvider
    module Common
      class Options < BaseModel
        # Prompting Options
        attribute :model, :string

        # Validations
        validates :model, presence: true

        # Backwards Compatibility
        alias_attribute :model_name, :model
      end
    end
  end
end
