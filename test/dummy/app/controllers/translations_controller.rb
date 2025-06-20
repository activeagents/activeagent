class TranslationsController < ApplicationController
  def create
    @message = Message.find(params[:message_id])

    TranslationAgent.with(
      message: @message.content,
      locale: :japanese,
      message_id: @message.id,
      context_id: @message.chat_id || "translation_#{@message.id}"
    ).translate.generate_later

    respond_to do |format|
      format.turbo_stream
    end
  end
end
