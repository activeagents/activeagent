class WeatherAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o-mini", instructions: "You're a weather agent. You can get weather information for locations."

  def get_weather
    prompt
  end
end
