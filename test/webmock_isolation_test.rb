# frozen_string_literal: true

require "test_helper"

# A stub registered in one test must not answer another test's requests.
class WebMockIsolationTest < ActiveSupport::TestCase
  test "a stub does not outlive a test whose teardown skips super" do
    leaky = Class.new(Minitest::Test) do
      def teardown; end

      def test_registers_a_stub
        stub_request(:post, "https://leak.example/v1/chat/completions")
      end
    end
    Minitest::Runnable.runnables.delete(leaky)

    result = leaky.new(:test_registers_a_stub).run

    assert result.passed?, result.failures.map(&:message).join("\n")
    leaked = WebMock::StubRegistry.instance.request_stubs.select { |stub| stub.request_pattern.to_s.include?("leak.example") }
    assert_empty leaked, "the stub survived the test that registered it"
  end
end
