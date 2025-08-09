# frozen_string_literal: true

require_relative "test_helper"

class ErrorsTest < ActiveSupport::TestCase
  test "ActiveAgentError is a StandardError" do
    assert ActiveAgent::Errors::ActiveAgentError < StandardError
  end

  test "GenerationProviderError inherits from ActiveAgentError" do
    assert ActiveAgent::Errors::GenerationProviderError < ActiveAgent::Errors::ActiveAgentError
  end

  test "GenerationProviderError is also a StandardError through inheritance" do
    assert ActiveAgent::Errors::GenerationProviderError < StandardError
  end
end
