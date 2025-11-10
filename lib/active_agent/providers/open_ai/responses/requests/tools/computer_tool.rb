# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Tools
            # Built-in computer tool (note: type should be "computer_use_preview" per schema)
            class ComputerTool < Base
              attribute :type, :string, as: "computer_use_preview"
              attribute :display_height, :integer # Required: height of the computer display
              attribute :display_width, :integer # Required: width of the computer display
              attribute :environment, :string # Required: type of computer environment to control

              validates :display_height, presence: true, numericality: { greater_than: 0 }
              validates :display_width, presence: true, numericality: { greater_than: 0 }
              validates :environment, presence: true
            end
          end
        end
      end
    end
  end
end
