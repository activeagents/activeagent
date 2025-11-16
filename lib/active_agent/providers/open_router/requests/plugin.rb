# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        # Plugin configuration for OpenRouter requests
        #
        # OpenRouter supports plugins that enhance model capabilities.
        # Currently supports the file-parser plugin for processing PDF documents.
        #
        # @example File parser plugin with PDF text extraction
        #   plugin = Plugin.new(
        #     id: 'file-parser',
        #     pdf: { engine: 'pdf-text' }
        #   )
        #
        # @example File parser plugin with OCR
        #   plugin = Plugin.new(
        #     id: 'file-parser',
        #     pdf: { engine: 'mistral-ocr' }
        #   )
        #
        # @see https://openrouter.ai/docs/plugins OpenRouter Plugins
        # @see Plugins::PdfConfig
        class Plugin < Common::BaseModel
          # @!attribute id
          #   @return [String] plugin identifier (currently only 'file-parser' is supported)
          attribute :id, :string

          # @!attribute pdf
          #   @return [Plugins::PdfConfig, nil] PDF processing configuration
          attribute :pdf, Plugins::PdfConfigType.new

          validates :id, presence: true
          validates :id, inclusion: { in: %w[file-parser] }, allow_nil: false
        end
      end
    end
  end
end
