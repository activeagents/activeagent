# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        # Represents a plugin configuration for OpenRouter requests.
        # Currently supports the file-parser plugin for PDF processing.
        #
        # @example
        #   plugin = Plugin.new(
        #     id: 'file-parser',
        #     pdf: { engine: 'pdf-text' }
        #   )
        class Plugin < Common::BaseModel
          attribute :id, :string
          attribute :pdf, Plugins::PdfConfigType.new

          validates :id, presence: true
          validates :id, inclusion: { in: %w[file-parser] }, allow_nil: false
        end
      end
    end
  end
end
