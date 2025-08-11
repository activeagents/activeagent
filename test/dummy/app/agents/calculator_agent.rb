class CalculatorAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o-mini", instructions: "You are a calculator assistant. Use the available tools to perform calculations."

  def add
    result = params[:a].to_f + params[:b].to_f
    prompt(content_type: "text/plain") do |format|
      format.text { render plain: result.to_s }
    end
  end

  def subtract
    result = params[:a].to_f - params[:b].to_f
    prompt(content_type: "text/plain") do |format|
      format.text { render plain: result.to_s }
    end
  end

  def multiply
    result = params[:a].to_f * params[:b].to_f
    prompt(content_type: "text/plain") do |format|
      format.text { render plain: result.to_s }
    end
  end

  def divide
    if params[:b].to_f == 0
      prompt(content_type: "text/plain") do |format|
        format.text { render plain: "Error: Division by zero" }
      end
    else
      result = params[:a].to_f / params[:b].to_f
      prompt(content_type: "text/plain") do |format|
        format.text { render plain: result.to_s }
      end
    end
  end

  def calculate_area
    width = params[:width].to_f
    height = params[:height].to_f
    result = width * height
    prompt(content_type: "text/plain") do |format|
      format.text { render plain: result.to_s }
    end
  end
end
