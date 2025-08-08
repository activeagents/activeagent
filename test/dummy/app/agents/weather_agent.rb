class WeatherAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o-mini", instructions: "You are a weather assistant. Use the available tools to provide weather information."

  def get_temperature
    # Simulate getting current temperature
    temperature = 22.5 # Celsius
    prompt(content_type: "text/plain") do |format|
      format.text { render plain: temperature.to_s }
    end
  end

  def get_weather_report
    prompt(content_type: "text/html") do |format|
      format.html { render "weather_report" }
    end
  end

  def convert_temperature
    from_unit = params[:from] || "celsius"
    to_unit = params[:to] || "fahrenheit"
    value = params[:value].to_f

    result = if from_unit.downcase == "celsius" && to_unit.downcase == "fahrenheit"
      (value * 9/5) + 32
    elsif from_unit.downcase == "fahrenheit" && to_unit.downcase == "celsius"
      (value - 32) * 5/9
    else
      value
    end

    prompt(content_type: "text/plain") do |format|
      format.text { render plain: result.round(2).to_s }
    end
  end
end