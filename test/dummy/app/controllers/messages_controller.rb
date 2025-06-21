class MessagesController < ApplicationController
  def create
    @chat = Chat.find(params[:chat_id])
    @message = @chat.messages.create(message_params.merge(role: "user"))

    SupportAgent.with(message: @message.content, context_id: @chat.id).prompt_context.generate_later

    respond_to do |format|
      format.turbo_stream
    end
  end

  private

  def message_params
    params.require(:message).permit(:content)
  end
end
