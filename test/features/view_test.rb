require "test_helper"

class ViewTest < ActiveSupport::TestCase
  class TestAgent < ActiveAgent::Base
    generate_with :mock

    def instructions_string
      prompt(instructions: "String Test")
    end

    def instructions_symbol
      prompt(instructions: :instructions_symbol_method)
    end

    def instructions_symbol_method
      "Instructions Symbol Test"
    end

    def instructions_array
      prompt(instructions: [
        "String Test One",
        "String Test Two"
      ])
    end

    def instructions_hash
      prompt(instructions: {
        template: "other_instructions",
        locals: {
          detail: "Hash Test"
        }
      })
    end
  end

  class TestInstructionsTextAgent < TestAgent
    def instructions_test
      prompt
    end
  end

  class TestInstructionsMarkdownAgent < TestAgent
    def instructions_test
      prompt
    end
  end

  MESSAGE = "test message"

  # Test: instructions_string returns a prompt with string instructions
  test "instructions_string generates response with content" do
    prompt = ViewTest::TestAgent.with(message: MESSAGE).instructions_string
    response = prompt.generate_now

    assert_not_nil response
    assert_not_nil response.message
    assert_not_nil response.message.content
    assert response.message.content.length > MESSAGE.length
  end

  # Test: instructions_symbol returns a prompt with instructions from method
  test "instructions_symbol generates response with content" do
    prompt = ViewTest::TestAgent.with(message: MESSAGE).instructions_symbol
    response = prompt.generate_now

    assert_not_nil response
    assert_not_nil response.message
    assert_not_nil response.message.content
    assert response.message.content.length > MESSAGE.length
  end

  # Test: instructions_array returns a prompt with array of instructions
  test "instructions_array generates response with content" do
    prompt = ViewTest::TestAgent.with(message: MESSAGE).instructions_array
    response = prompt.generate_now

    assert_not_nil response
    assert_not_nil response.message
    assert_not_nil response.message.content
    assert response.message.content.length > MESSAGE.length
  end

  # Test: instructions_hash returns a prompt with instructions from template
  test "instructions_hash generates response with content" do
    prompt = ViewTest::TestAgent.with(message: MESSAGE).instructions_hash
    response = prompt.generate_now

    assert_not_nil response
    assert_not_nil response.message
    assert_not_nil response.message.content
    assert response.message.content.length > MESSAGE.length
  end

  # Test: TestInstructionsTextAgent loads instructions from text template
  test "instructions_test with text template generates response with content" do
    prompt = ViewTest::TestInstructionsTextAgent.with(message: MESSAGE).instructions_test
    response = prompt.generate_now

    assert_not_nil response
    assert_not_nil response.message
    assert_not_nil response.message.content
    assert response.message.content.length > MESSAGE.length
  end

  # Test: TestInstructionsMarkdownAgent loads instructions from markdown template
  test "instructions_test with markdown template generates response with content" do
    prompt = ViewTest::TestInstructionsMarkdownAgent.with(message: MESSAGE).instructions_test
    response = prompt.generate_now

    assert_not_nil response
    assert_not_nil response.message
    assert_not_nil response.message.content
    assert response.message.content.length > MESSAGE.length
  end
end
