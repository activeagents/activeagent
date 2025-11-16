# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Plugins
          # PDF processing configuration for file-parser plugin
          #
          # OpenRouter provides multiple PDF processing engines with different
          # capabilities and costs:
          #
          # - **mistral-ocr**: Best for scanned documents or PDFs with images
          #   - Cost: $2 per 1,000 pages
          #   - Use when: Document is image-heavy or has poor text extraction
          #
          # - **pdf-text**: Best for well-structured PDFs with clear text content
          #   - Cost: Free
          #   - Use when: Document has clean, extractable text
          #
          # - **native**: Use model's native file processing capabilities
          #   - Cost: Charged as input tokens
          #   - Use when: Model supports native file input
          #
          # If no engine is specified, OpenRouter defaults to the model's native
          # file processing if available, otherwise uses mistral-ocr.
          #
          # @example Text extraction (free)
          #   pdf_config = PdfConfig.new(engine: 'pdf-text')
          #
          # @example OCR for scanned documents
          #   pdf_config = PdfConfig.new(engine: 'mistral-ocr')
          #
          # @example Use model's native processing
          #   pdf_config = PdfConfig.new(engine: 'native')
          #
          # @see https://openrouter.ai/docs/plugins#file-parser OpenRouter File Parser Plugin
          # @see Plugin
          class PdfConfig < Common::BaseModel
            # @!attribute engine
            #   @return [String, nil] PDF processing engine
            #     Options: 'mistral-ocr', 'pdf-text', 'native'
            attribute :engine, :string

            validates :engine, inclusion: { in: %w[mistral-ocr pdf-text native] }, allow_nil: true
          end
        end
      end
    end
  end
end
