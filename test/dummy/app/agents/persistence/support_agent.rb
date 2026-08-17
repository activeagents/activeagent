# frozen_string_literal: true

# Agents for the cross-repo integration suite (test/integration/solid_agent).
#
# Namespaced Persistence:: rather than SolidAgent:: — that constant belongs
# to the gem. Everything here uses the mock provider, so the suite is
# deterministic and free: what it proves is that the two gems compose, not
# what a model says.
module Persistence
  # HasContext against the host-app models the install generator writes.
  class SupportAgent < ApplicationAgent
    include SolidAgent::HasContext

    generate_with :mock, model: "mock-gpt-4o-mini"

    # A named context renames the generated methods (load_conversation,
    # conversation_messages, ...) and, on its own, would infer the models
    # Conversation / ConversationMessage / ConversationGeneration. class_name
    # points it back at the models the install generator writes; without it,
    # a host app needs `rails generate solid_agent:context conversation`.
    has_context :conversation, class_name: "AgentContext", contextual: :user

    def answer
      load_conversation(contextable: params[:user])

      prompt messages: conversation_messages + [
        { role: "user", content: params[:message] }
      ]
    end
  end
end
