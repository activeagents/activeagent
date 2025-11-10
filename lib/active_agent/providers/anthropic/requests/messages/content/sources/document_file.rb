# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Content
          module Sources
            # File-based document source
            class DocumentFile < Base
              attribute :type, :string, as: "file"
              attribute :file_id, :string

              validates :file_id, presence: true
            end
          end
        end
      end
    end
  end
end
