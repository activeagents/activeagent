# frozen_string_literal: true

require "active_agent/base"

class ParamsAgent < ActiveAgent::Base
  # generate_with :openai

  before_action { @instructions, @context, @content = params[:instructions], params[:context], params[:content] }

  # default instructions: proc { @instructions }, context: -> { @context }

  def welcome
    prompt(instructions: @instructions, context: @context, content: params[:content]) do |format|
      format.text { render plain: "Instructions: #{@instructions}" }
      format.json { render json: {instructions: @instructions} }
    end
  end
end
