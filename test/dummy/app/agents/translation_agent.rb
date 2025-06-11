class TranslationAgent < ApplicationAgent
  generate_with :openai, instructions: "Translate the given text from one language to another."
  before_generation :load_message
  after_generation :broadcast_translation

  def translate
    prompt(messages: params[:messages], context_id: params[:context_id])
  end

  private

  def load_message
    @message = Message.find(params[:message_id])
  end

  def broadcast_translation
    @translation = @message.find_or_create_streaming_translation(generation_provider.response)
  end
end
