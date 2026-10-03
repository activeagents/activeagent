# frozen_string_literal: true

require "test_helper"

class InputRequestTest < ActiveSupport::TestCase
  test "each kind has a constructor" do
    assert_equal :text,    ActiveAgent::InputRequest.text("Why?").kind
    assert_equal :confirm, ActiveAgent::InputRequest.confirm("Go ahead?").kind
    assert_equal :secret,  ActiveAgent::InputRequest.secret("Token?").kind
    assert_equal :choice,  ActiveAgent::InputRequest.choice("Which?", options: %w[a b]).kind
  end

  test "an unknown kind, a blank prompt, or a choice without options is refused" do
    assert_raises(ArgumentError) { ActiveAgent::InputRequest.new(kind: :vote, prompt: "Which?") }
    assert_raises(ArgumentError) { ActiveAgent::InputRequest.text("") }
    assert_raises(ArgumentError) { ActiveAgent::InputRequest.new(kind: :choice, prompt: "Which?") }
  end

  test "a request survives a JSON round trip" do
    request = ActiveAgent::InputRequest.choice(
      "Which team?",
      options: [ { value: :billing, label: "Billing" }, { value: :shipping, label: "Shipping" } ],
      schema: { type: :string },
      metadata: { ticket: 42 }
    ).for_tool_call(id: "call_1", name: "route_ticket")

    restored = ActiveAgent::InputRequest.from_h(JSON.parse(request.to_h.to_json))

    assert_equal request, restored
    assert_equal "choice", request.to_h[:kind]
    assert_equal %w[billing shipping], restored.choice_values
  end

  test "to_h leaves out attributes that were never set" do
    assert_equal({ kind: "text", prompt: "Why?", metadata: {} }, ActiveAgent::InputRequest.text("Why?").to_h)
  end

  test "an answer is readable only for the call being dispatched" do
    ActiveAgent::InputRequest.dispatching("call_1", answer: "yes") do
      assert_equal "call_1", ActiveAgent::InputRequest.current_tool_call_id
      assert_equal "yes", ActiveAgent::InputRequest.answer_for("call_1")
      assert_nil ActiveAgent::InputRequest.answer_for("call_2")

      ActiveAgent::InputRequest.dispatching("nested") do
        assert_nil ActiveAgent::InputRequest.answer_for("call_1"), "a nested generation's calls do not see the outer answer"
      end

      assert_equal "yes", ActiveAgent::InputRequest.answer_for("call_1")
    end

    assert_nil ActiveAgent::InputRequest.current_tool_call_id
    assert_nil ActiveAgent::InputRequest.answer_for("call_1")
  end

  test "scrub replaces secrets in strings at any depth, keys included" do
    value = { "note" => "token abc123 used", nested: [ "abc123", { "abc123" => 1 } ], count: 3 }

    scrubbed = ActiveAgent::InputRequest.scrub(value, [ "abc123" ])

    assert_equal({ "note" => "token [FILTERED] used", nested: [ "[FILTERED]", { "[FILTERED]" => 1 } ], count: 3 }, scrubbed)
  end

  test "scrub replaces the longer of two overlapping secrets first" do
    assert_equal "[FILTERED]", ActiveAgent::InputRequest.scrub("abcdef", [ "abc", "abcdef" ])
  end

  test "scrub reads other objects in their JSON form" do
    record = Struct.new(:token) do
      def as_json(*) = { "token" => token }
    end

    assert_equal({ "token" => "[FILTERED]" }, ActiveAgent::InputRequest.scrub(record.new("abc123"), [ "abc123" ]))
  end

  test "scrub with no secrets returns the value itself" do
    value = Object.new

    assert_same value, ActiveAgent::InputRequest.scrub(value, [ "", nil ])
  end

  test "scrub leaves an InputRequest as it is" do
    request = ActiveAgent::InputRequest.text("abc123?")

    assert_same request, ActiveAgent::InputRequest.scrub(request, [ "abc123" ])
  end

  test "scrub_error copies an error only when its message holds a secret" do
    clean = RuntimeError.new("timed out")
    dirty = RuntimeError.new("bad token abc123")

    assert_same clean, ActiveAgent::InputRequest.scrub_error(clean, [ "abc123" ])

    scrubbed = ActiveAgent::InputRequest.scrub_error(dirty, [ "abc123" ])
    assert_instance_of RuntimeError, scrubbed
    assert_equal "bad token [FILTERED]", scrubbed.message
  end
end
