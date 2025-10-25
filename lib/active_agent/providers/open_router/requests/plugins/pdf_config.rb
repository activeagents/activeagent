# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Plugins
          # Configuration for PDF processing in the file-parser plugin.
          #
          # OpenRouter provides several PDF processing engines:
          # - "mistral-ocr": Best for scanned documents or PDFs with images ($2 per 1,000 pages)
          # - "pdf-text": Best for well-structured PDFs with clear text content (Free)
          # - "native": Only available for models that support file input natively (charged as input tokens)
          #
          # If you don't explicitly specify an engine, OpenRouter will default first to the model's
          # native file processing capabilities, and if that's not available, will use the "mistral-ocr" engine.
          #
          # @example
          #   pdf_config = PdfConfig.new(engine: 'pdf-text')
          class PdfConfig < Common::BaseModel
            attribute :engine, :string

            validates :engine, inclusion: { in: %w[mistral-ocr pdf-text native] }, allow_nil: true
          end
        end
      end
    end
  end
end
