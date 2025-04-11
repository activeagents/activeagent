# test/application_agent_test.rb
require "test_helper"

class ApplicationAgentTest < ActiveSupport::TestCase
  test "it renders a prompt with an empty message" do
    assert_equal "", ApplicationAgent.text_prompt.message.content
  end

  test "it renders a prompt with an plain text message" do
    message = "Test Application Agent"
    assert_equal "Test Application Agent", ApplicationAgent.with(message: "Test Application Agent").text_prompt.message.content
  end
end
