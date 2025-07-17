module ScopedAgents
  class TranslationAgentWithCustomInstructionsTemplate < ApplicationAgent
    generate_with :openai, instructions: {
      template: :custom_instructions, locals: {from: "English", to: "French"}
    }

    before_action :add_custom_instructions

    def translate
      prompt
    end

    def translate_with_overridden_instructions
      prompt(instructions: {template: :overridden_instructions})
    end

    private

    def add_custom_instructions
      @additional_instruction = "translation additional instruction"
    end
  end
end
