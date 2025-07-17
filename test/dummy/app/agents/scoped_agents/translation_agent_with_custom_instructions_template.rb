module ScopedAgents
  class TranslationAgentWithCustomInstructionsTemplate < ApplicationAgent
    generate_with :openai, instructions: {
      template: :custom_instructions, locals: { from: "English", to: "French" }
    }

    def translate
      @additional_instruction = "translation additional instruction"
      prompt
    end

    def translate_with_overridden_instructions
      prompt(instructions: { template: :overridden_instructions })
    end
  end
end
