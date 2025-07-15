module ScopedAgents
  class TranslationAgentWithDefaultInstructionsTemplate < ApplicationAgent
    generate_with :openai

    def translate
      prompt
    end
  end
end
