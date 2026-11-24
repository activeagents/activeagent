# The chat panel. Each message is one run of the dashboard agent, on behalf of
# the signed-in teammate, pinned to the session's conversation.
class AssistantMessagesController < ApplicationController
  def create
    agent = Assistant.agent
    message = params[:message].to_s.strip

    if agent.nil?
      flash[:alert] = "No agent yet. Build one in the dashboard first."
    elsif message.present?
      run = agent.test_execute(message, actor: current_user, context_id: Assistant.conversation(agent, session).id)
      flash[:alert] = "The agent could not answer: #{run.error_message}" if run.failed?
    end

    redirect_back fallback_location: root_path
  end

  # Start a new conversation. The old one stays in the dashboard.
  def destroy
    session.delete(:assistant_context_id)
    redirect_back fallback_location: root_path
  end
end
