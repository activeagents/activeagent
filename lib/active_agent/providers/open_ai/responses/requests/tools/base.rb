# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Tools
            # Base class for tools in Responses API
            class Base < Common::BaseModel
              attribute :type, :string

              validates :type, inclusion: {
                in: %w[function custom web_search web_search_2025_08_26 code_interpreter file_search computer_use_preview mcp image_generation local_shell web_search_preview web_search_preview_2025_03_11],
                allow_nil: true
              }
            end
          end
        end
      end
    end
  end
end
