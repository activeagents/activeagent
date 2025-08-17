class PrivacyFocusedAgent < ApplicationAgent
  # Configure OpenRouter with strict data privacy settings
  # region privacy_agent_config
  generate_with :open_router, 
    model: "openai/gpt-4o-mini",
    data_collection: "deny",  # Prevent all providers from collecting data
    enable_fallbacks: true,
    fallback_models: ["openai/gpt-3.5-turbo"]
  # endregion privacy_agent_config

  # Process sensitive financial data without data collection
  # region process_financial_data
  def analyze_financial_data
    @data = params[:financial_data]
    @analysis_type = params[:analysis_type] || "summary"
    
    prompt(
      message: build_financial_message,
      instructions: "You are analyzing sensitive financial data. Ensure privacy and confidentiality."
    )
  end
  # endregion process_financial_data

  # Process medical records with selective provider data collection
  # region process_medical_records
  def process_medical_records
    # Only allow specific trusted providers to collect data
    prompt(
      message: "Analyze the following medical record: #{params[:record]}",
      instructions: "Handle medical data with utmost privacy",
      options: {
        provider: {
          data_collection: ["OpenAI"]  # Only OpenAI can collect this data
        }
      }
    )
  end
  # endregion process_medical_records

  private

  def build_financial_message
    <<~MESSAGE
      Analyze the following financial data:
      #{@data}
      
      Analysis type: #{@analysis_type}
      
      Please provide:
      1. Key financial metrics
      2. Risk assessment
      3. Recommendations
    MESSAGE
  end
end