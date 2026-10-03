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

  test "the arguments of the paused call survive a JSON round trip" do
    request = ActiveAgent::InputRequest.confirm("Go ahead?")
                                       .for_tool_call(id: "call_1", name: "issue_refund", arguments: { order_id: 7, amount: 40 })

    restored = ActiveAgent::InputRequest.from_h(JSON.parse(request.to_h.to_json))

    assert_equal({ "order_id" => 7, "amount" => 40 }, restored.arguments)
    assert_equal request, restored
  end

  # A checkpoint whose tool-call turn is a reasoning item and two function
  # calls, as OpenAI Responses sends one.
  def multi_item_checkpoint(**overrides)
    {
      "version" => ActiveAgent::InputRequest::Resume::VERSION,
      "messages" => [
        { "role" => "user", "content" => "Refund order 7" },
        { "type" => "reasoning", "id" => "rs_1", "summary" => [] },
        { "type" => "function_call", "call_id" => "call_1", "name" => "lookup_order", "arguments" => "{}" },
        { "type" => "function_call", "call_id" => "call_2", "name" => "issue_refund", "arguments" => "{}" }
      ],
      "tool_call_turn_size" => 3,
      "completed_results" => { "call_1" => { "total" => 40 } },
      "input_requests" => [ ActiveAgent::InputRequest.confirm("Refund?").for_tool_call(id: "call_2", name: "issue_refund").to_h ]
    }.merge(overrides.stringify_keys)
  end

  test "a resume splits off a tool-call turn of several items" do
    resume = ActiveAgent::InputRequest::Resume.new(checkpoint: multi_item_checkpoint, answers: { "call_2" => true })

    assert_equal [ "user" ], resume.messages.map { _1[:role] }
    assert_equal %w[reasoning function_call function_call], resume.tool_call_turn.map { _1[:type] }
  end

  test "a checkpoint without tool_call_turn_size takes the last message as the tool-call turn" do
    resume = ActiveAgent::InputRequest::Resume.new(checkpoint: multi_item_checkpoint.except("tool_call_turn_size"), answers: { "call_2" => true })

    assert_equal 3, resume.messages.size
    assert_equal [ "call_2" ], resume.tool_call_turn.map { _1[:call_id] }
  end

  test "a checkpoint whose tool-call turn is larger than its conversation is refused" do
    assert_raises(ActiveAgent::InputRequest::ResumeError) do
      ActiveAgent::InputRequest::Resume.new(checkpoint: multi_item_checkpoint(tool_call_turn_size: 5), answers: { "call_2" => true })
    end
  end

  test "an answer is readable only for the call being dispatched" do
    ActiveAgent::InputRequest.dispatching("call_1", answer: "yes") do
      assert_equal "call_1", ActiveAgent::InputRequest.current_tool_call_id
      assert_equal "yes", ActiveAgent::InputRequest.answer_for("call_1")
      assert_nil ActiveAgent::InputRequest.answer_for("call_2")

      ActiveAgent::InputRequest.dispatching("nested") do
        assert_nil ActiveAgent::InputRequest.answer_for("call_1"), "a nested generation's calls do not see the outer answer"
      end

      ActiveAgent::InputRequest.dispatching(nil) do
        assert_nil ActiveAgent::InputRequest.current_tool_call_id
        assert_nil ActiveAgent::InputRequest.answer_for("call_1"), "a call run outside dispatch does not see the outer answer"
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

  test "scrub compares a number in its string form" do
    assert_equal({ "pin" => "[FILTERED]", "total" => 40 }, ActiveAgent::InputRequest.scrub({ "pin" => 4821, "total" => 40 }, [ "4821" ]))
  end

  # Errors whose message is built from their own state, not from the text
  # they were raised with.
  class TokenError < StandardError
    def initialize(token)
      @token = token
      super("rejected")
    end

    def message = "token #{@token} rejected"
  end

  def raised
    yield
  rescue StandardError => error
    error
  end

  def scrubbed(error, secrets = [ "abc123" ])
    raised { ActiveAgent::InputRequest.raise_scrubbed(error, secrets) }
  end

  test "raise_scrubbed raises the error itself when no message in its chain holds a secret" do
    clean = raised { raise RuntimeError, "timed out" }

    assert_same clean, scrubbed(clean)
  end

  test "raise_scrubbed raises a copy of the error with the secret replaced" do
    dirty = raised { raise ArgumentError, "bad token abc123" }

    error = scrubbed(dirty)

    assert_instance_of ArgumentError, error
    assert_equal "bad token [FILTERED]", error.message
    assert_equal dirty.backtrace, error.backtrace
    assert_nil error.cause
  end

  test "raise_scrubbed raises a ScrubbedError when a copy of the error still reports the secret" do
    dirty = raised { raise TokenError.new("abc123") }

    error = scrubbed(dirty)

    assert_instance_of ActiveAgent::InputRequest::ScrubbedError, error
    assert_equal "#{TokenError.name}: token [FILTERED] rejected", error.message
    assert_equal dirty.backtrace, error.backtrace
  end

  test "raise_scrubbed replaces a cause that holds a secret" do
    dirty = raised do
      begin
        raise TokenError.new("abc123")
      rescue TokenError
        raise RuntimeError, "deploy failed"
      end
    end

    error = scrubbed(dirty)

    assert_equal "deploy failed", error.message
    assert_instance_of ActiveAgent::InputRequest::ScrubbedError, error.cause
    assert_equal "#{TokenError.name}: token [FILTERED] rejected", error.cause.message
    assert_nil error.cause.cause
  end

  test "raise_scrubbed keeps a cause that holds no secret" do
    dirty = raised do
      begin
        raise IOError, "connection reset"
      rescue IOError
        raise RuntimeError, "token abc123 failed"
      end
    end

    error = scrubbed(dirty)

    assert_equal "token [FILTERED] failed", error.message
    assert_same dirty.cause, error.cause
  end
end
