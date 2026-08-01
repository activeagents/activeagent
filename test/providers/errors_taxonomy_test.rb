# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/active_agent/providers/mock_provider"

class ErrorsTaxonomyTest < ActiveSupport::TestCase
  Errors = ActiveAgent::Providers::Errors

  # Vendor-SDK-shaped exceptions (the official gems expose #status).
  class FakeStatusError < StandardError
    def initialize(message, status)
      super(message)
      @status = status
    end
    attr_reader :status
  end

  class RateLimitError < StandardError; end

  test "classifies by vendor class name" do
    error = Errors::Taxonomy.normalize(RateLimitError.new("slow down"))
    assert_instance_of Errors::RateLimited, error
    assert_equal "slow down", error.message
  end

  test "classifies by HTTP status" do
    assert_instance_of Errors::RateLimited, Errors::Taxonomy.normalize(FakeStatusError.new("429", 429))
    assert_instance_of Errors::AuthenticationFailed, Errors::Taxonomy.normalize(FakeStatusError.new("bad key", 401))
    assert_instance_of Errors::InvalidRequest, Errors::Taxonomy.normalize(FakeStatusError.new("bad params", 400))
    assert_instance_of Errors::ServiceUnavailable, Errors::Taxonomy.normalize(FakeStatusError.new("boom", 503))
    assert_instance_of Errors::ServiceUnavailable, Errors::Taxonomy.normalize(FakeStatusError.new("overloaded", 529))
  end

  test "context overflow and content filter win over the generic 400" do
    context_error = Errors::Taxonomy.normalize(FakeStatusError.new("prompt is too long: 250000 tokens > maximum context", 400))
    assert_instance_of Errors::ContextLengthExceeded, context_error

    filter_error = Errors::Taxonomy.normalize(FakeStatusError.new("Response blocked by content filter", 400))
    assert_instance_of Errors::ContentFiltered, filter_error
  end

  test "captures status and provider tag" do
    error = Errors::Taxonomy.normalize(FakeStatusError.new("429", 429), provider_tag: "Anthropic")
    assert_equal 429, error.status
    assert_equal "Anthropic", error.provider_tag
  end

  test "ordinary Ruby errors pass through untouched" do
    original = NoMethodError.new("undefined method")
    assert_same original, Errors::Taxonomy.normalize(original)

    plain = StandardError.new("something odd")
    assert_same plain, Errors::Taxonomy.normalize(plain)
  end

  test "already-normalized errors pass through" do
    original = Errors::RateLimited.new("again")
    assert_same original, Errors::Taxonomy.normalize(original)
  end

  test "provider raises the typed error with the original as cause" do
    provider = ActiveAgent::Providers::MockProvider.new(service: "Mock")

    raised = assert_raises(Errors::RateLimited) do
      provider.send(:with_exception_handling) { raise FakeStatusError.new("too fast", 429) }
    end

    assert_instance_of FakeStatusError, raised.cause
    assert_equal "Mock", raised.provider_tag
  end

  test "exception_handler receives the typed error" do
    seen = nil
    provider = ActiveAgent::Providers::MockProvider.new(
      service: "Mock",
      exception_handler: ->(exception) { seen = exception }
    )

    provider.send(:with_exception_handling) { raise FakeStatusError.new("too fast", 429) }

    assert_instance_of Errors::RateLimited, seen
  end
end
