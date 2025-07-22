class TranslationAgent < ApplicationAgent
  generate_with :openai, instructions: "Translate the given text from one language to another.", stream: false

  def translate
    prompt
  end
end
