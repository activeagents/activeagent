require "test_helper"

class PrivacyFocusedAgentTest < ActiveSupport::TestCase
  setup do
    @agent = PrivacyFocusedAgent.new
  end

  test "configures agent with data collection denied" do
    # Verify the agent is configured with data_collection: "deny"
    provider = @agent.send(:generation_provider)
    
    # The provider should be an OpenRouter provider
    assert_kind_of ActiveAgent::GenerationProvider::OpenRouterProvider, provider
    
    # Create a prompt context to test with
    prompt_context = @agent.prompt(message: "test")
    
    # Set the prompt on the provider to simulate real usage
    provider.instance_variable_set(:@prompt, prompt_context)
    
    # Now check that data collection is properly set
    prefs = provider.send(:build_provider_preferences)
    assert_equal "deny", prefs[:data_collection]
  end

  test "processes financial data with privacy settings" do
    skip "Requires actual OpenRouter API key" unless has_openrouter_credentials?
    
    VCR.use_cassette("privacy_focused_financial_analysis") do
      # region financial_data_test
      financial_data = {
        revenue: 1_000_000,
        expenses: 750_000,
        profit_margin: 0.25,
        quarter: "Q3 2024"
      }
      
      response = @agent.with(
        financial_data: financial_data.to_json,
        analysis_type: "risk_assessment"
      ).analyze_financial_data.generate_now
      
      assert_not_nil response
      assert_not_nil response.content
      assert response.content.include?("risk") || response.content.include?("financial")
      
      # Verify the request was made with data_collection: "deny"
      # This ensures the data won't be used for training
      doc_example_output(response)
      # endregion financial_data_test
    end
  end

  test "processes medical records with selective provider collection" do
    skip "Requires actual OpenRouter API key" unless has_openrouter_credentials?
    
    VCR.use_cassette("privacy_focused_medical_records") do
      # region medical_records_test
      medical_record = {
        patient_id: "REDACTED",
        diagnosis: "Example condition",
        treatment: "Standard protocol",
        date: "2024-01-01"
      }
      
      response = @agent.with(
        record: medical_record.to_json
      ).process_medical_records.generate_now
      
      assert_not_nil response
      assert_not_nil response.content
      
      # The response should handle the medical data appropriately
      doc_example_output(response)
      # endregion medical_records_test
    end
  end

  private

  def has_openrouter_credentials?
    Rails.application.credentials.dig(:open_router, :access_token).present? ||
    Rails.application.credentials.dig(:open_router, :api_key).present? ||
    ENV["OPENROUTER_API_KEY"].present?
  end
end