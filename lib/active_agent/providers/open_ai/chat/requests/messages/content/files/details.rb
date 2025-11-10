# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            module Content
              module Files
                # Represents the nested file object within File content part
                class Details < Common::BaseModel
                  # The base64 encoded file data, used when passing the file to the model as a string
                  attribute :file_data, :string

                  # The ID of an uploaded file to use as input
                  attribute :file_id, :string

                  # The name of the file, used when passing the file to the model as a string
                  attribute :filename, :string

                  # Override serialize to strip data URI prefix from file_data
                  def file_data=(value)
                    # Strip data URI prefix from file_data if present
                    if value&.match?(/\Adata:[^;]+;base64,/)
                      value = value.sub(/\Adata:[^;]+;base64,/, "")
                    end

                    super(value)
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
