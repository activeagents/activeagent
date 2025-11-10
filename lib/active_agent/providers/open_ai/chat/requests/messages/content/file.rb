# frozen_string_literal: true

require_relative "base"
require_relative "files/_types"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            module Content
              # File content part
              class File < Base
                attribute :type, :string, as: "file"
                attribute :file, Files::DetailsType.new

                validates :file, presence: true
              end
            end
          end
        end
      end
    end
  end
end
