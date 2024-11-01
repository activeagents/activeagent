# frozen_string_literal: true

class ParamsAgent < ActiveAgent::Base
  # generate_with :openai

  before_action { @instructions, @context, @content = params[:instructions], params[:context], params[:content] }

  # default instructions: proc { @instructions }, context: -> { @context }

  def welcome
    prompt(instructions: @instructions, context: @context, content: params[:content]) do |format|
      format.text { render plain: "Instructions: #{@instructions}" }
    end
  end
end
