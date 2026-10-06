# frozen_string_literal: true

require "test_helper"
require "json"

# `ActiveAgent::Evals::RubyLLM.replay` against what the installed ruby_llm
# actually produces: a tool-calling conversation driven through RubyLLM
# itself, read back as `RubyLLM::Message` values and as `acts_as_chat`
# records. The conversation runs out of process (support/
# ruby_llm_conversation_script.rb) so its database, configuration and HTTP
# stubs never touch the suite's own.
class EvalsRubyLLMConversationTest < ActiveSupport::TestCase
  SCRIPT = File.expand_path("support/ruby_llm_conversation_script.rb", __dir__)
  LIB = File.expand_path("../../lib", __dir__)

  EXPECTED_ANSWER = "Order ABC-123 shipped on Monday."

  # The order the model made the calls in, which is not their ids' order,
  # with the three failures RubyLLM itself reports three different ways: a
  # tool returning an error Hash, a tool returning MCP-style JSON, and a call
  # to a tool the model was never given.
  EXPECTED_TOOL_CALLS = [
    [ "lookup_order", false, nil ],
    [ "failing_hash", true, "backend timed out" ],
    [ "failing_json", true, "MCP tool failing_json timed out" ],
    [ "github__search_issues", true, /\AModel tried to call unavailable tool `github__search_issues`/ ]
  ].freeze

  test "a conversation replays the same from RubyLLM messages and from acts_as_chat records" do
    output = run_conversation

    assert_replays_the_conversation output.fetch("values"), "RubyLLM::Message values (ruby_llm #{output['ruby_llm']})"
    skip output["records"]["skipped"] if output["records"].key?("skipped")

    assert_replays_the_conversation output.fetch("records"), "acts_as_chat records (ruby_llm #{output['ruby_llm']})"
  end

  test "records mid-way through RubyLLM 2's upgrade read the conversation, not the legacy columns" do
    version = Gem.loaded_specs["ruby_llm"]&.version
    skip "the upgrade window is a RubyLLM 2 state (ruby_llm #{version})" if version && version < Gem::Version.new("2")

    output = run_conversation("legacy")
    skip output["records"]["skipped"] if output["records"].key?("skipped")

    assert output["legacy"], "the script ran without the legacy columns"
    assert_replays_the_conversation output.fetch("records"), "records with legacy columns"
  end

  private

  def run_conversation(*arguments)
    # -EUTF-8: RubyLLM reads its bundled model registry with the default
    # external encoding, which a machine without a UTF-8 locale leaves ASCII.
    raw = IO.popen([ RbConfig.ruby, "-EUTF-8", "-I#{LIB}", SCRIPT, *arguments ], err: %i[child out], &:read)
    JSON.parse(raw.lines.last.to_s)
  rescue JSON::ParserError
    flunk "the conversation script did not print its replays:\n#{raw}"
  end

  def assert_replays_the_conversation(replay, label)
    assert_equal EXPECTED_ANSWER, replay["answer"], label
    assert_nil replay["error"], label

    calls = replay.fetch("tool_calls")
    assert_equal EXPECTED_TOOL_CALLS.map(&:first), calls.map { |call| call["name"] }, "#{label}: call order"
    EXPECTED_TOOL_CALLS.zip(calls).each do |(name, errored, detail), call|
      assert_equal errored, call["error"], "#{label}: #{name} error"
      case detail
      when nil then assert_nil call["detail"], "#{label}: #{name} detail"
      when Regexp then assert_match detail, call["detail"], "#{label}: #{name} detail"
      else assert_equal detail, call["detail"], "#{label}: #{name} detail"
      end
    end

    # Three rounds of 100, 200 and 300 prompt tokens, 40 and 150 of them read
    # from the cache: the replay counts the whole prompt.
    assert_equal 600, replay["input_tokens"], label
    assert_equal 60, replay["output_tokens"], label
    assert_operator replay["cost"].to_f, :>, 0, "#{label}: RubyLLM priced every round"
  end
end
