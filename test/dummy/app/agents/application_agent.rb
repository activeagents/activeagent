class ApplicationAgent < ActiveAgent::Base
  layout "agent"

  generate_with :openai,
    model: "gpt-4o-mini",
    instructions: "You're just a basic agent",
    stream: true

  def text_prompt
    prompt(stream: params[:stream], message: params[:message], context_id: params[:context_id]) { |format| format.text { render plain: params[:message] } }
  end
end
