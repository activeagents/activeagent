# frozen_string_literal: true

require_relative "../messages/_types"

module ActiveAgent
  module Providers
    module Common
      module Responses
        module Types
          # Type for Messages array - delegates to the shared common messages type
          class MessagesType < Common::Messages::Types::MessagesType
          end
        end
      end
    end
  end
end
