# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/active_agent/providers/mock_provider"

# A tool returns an ActiveAgent::InputRequest to ask the user something; the
# generation pauses with a checkpoint, and Generation#resume_now continues it
# with the answers. These tests run the real provider tool loop against a
# scripted model, so no request leaves the process.
class InputRequestsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # A fake model that answers with a scripted sequence of assistant turns,
  # in the Anthropic content-block shape, and records every request.
  class ScriptedProvider < ActiveAgent::Providers::MockProvider
    # Type resolution derives from the class name; keep the Mock identity.
    def self.name = "ActiveAgent::Providers::MockProvider"

    class << self
      attr_accessor :turns, :requests

      def script(*turns)
        self.turns    = turns
        self.requests = []
      end
    end

    def api_prompt_execute(parameters)
      ScriptedProvider.requests << parameters[:messages].deep_dup

      content = ScriptedProvider.turns.shift || [ { type: "text", text: "All done." } ]
      { id: "msg_#{ScriptedProvider.requests.size}", type: "message", role: "assistant", content:, model: "mock-model", stop_reason: "end_turn" }
    end

    def process_prompt_finished_extract_function_calls
      message_stack
        .select { _1[:role].to_s == "assistant" }
        .flat_map { Array(_1[:content]) }
        .select { _1.is_a?(Hash) && _1[:type].to_s == "tool_use" }
    end

    def process_function_calls(calls)
      results = dispatch_tool_calls(calls) { |call| call_tool_function(call[:name], **call[:input].to_h.symbolize_keys) }
      return unless results

      content = calls.zip(results).map { |call, result| { type: "tool_result", tool_use_id: call[:id], content: result.to_json } }
      message_stack.push({ role: "user", content: })
    end
  end

  # A provider whose tool loop never adopted dispatch_tool_calls.
  class UnpausableProvider < ScriptedProvider
    def process_function_calls(calls)
      calls.each do |call|
        result = call_tool_function(call[:name], **call[:input].to_h.symbolize_keys)
        message_stack.push({ role: "user", content: [ { type: "tool_result", tool_use_id: call[:id], content: result.to_json } ] })
      end
    end
  end

  def self.tool_use(id, name, **input) = { type: "tool_use", id:, name:, input: }

  class RefundAgent < ApplicationAgent
    generate_with :mock, model: "mock-model"
    self._prompt_provider_klass = ScriptedProvider

    class_attribute :calls, default: []

    def triage(order_id:)
      prompt(message: "Handle order #{order_id}", instructions: "You handle refunds.")
    end

    def lookup_order(order_id:)
      record(:lookup_order)
      { order_id:, total: 40 }
    end

    def issue_refund(order_id:, amount:)
      return ActiveAgent::InputRequest.confirm("Refund #{amount} on order #{order_id}?") unless input_answer

      record(:issue_refund, input_answer)
      { refunded: amount }
    end

    def close_ticket
      record(:close_ticket)
      nil
    end

    def ask_reason
      reason = input_answer
      return ActiveAgent::InputRequest.text("Why is the customer asking?") unless reason
      return ActiveAgent::InputRequest.choice("Which team?", options: %w[billing shipping]) if reason == "escalate"

      record(:ask_reason, reason)
      { reason: }
    end

    def deploy(environment:)
      token = input_answer
      return ActiveAgent::InputRequest.secret("Paste a deploy token for #{environment}") unless token

      record(:deploy)
      raise ArgumentError, "token #{token} was rejected" if environment == "broken"

      { deployed: environment, note: "used token #{token}" }
    end

    private

    def record(*entry) = calls << entry
  end

  setup do
    RefundAgent.calls = []
  end

  def paused_triage(*turns)
    ScriptedProvider.script(*turns)
    RefundAgent.triage(order_id: 7).generate_now
  end

  def resume(response, answers)
    RefundAgent.triage(order_id: 7).resume_now(checkpoint: JSON.parse(response.checkpoint.to_json), answers:)
  end

  ##### Pausing #############################################################

  test "a tool that returns an InputRequest pauses the generation" do
    response = paused_triage([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])

    assert response.awaiting_input?
    request = response.input_requests.sole
    assert_equal :confirm, request.kind
    assert_equal "call_1", request.tool_call_id
    assert_equal "issue_refund", request.tool_name
    assert_equal "Refund 40 on order 7?", request.prompt
    assert_equal 1, ScriptedProvider.requests.size, "a paused turn sends nothing back to the model"
    assert_empty RefundAgent.calls
  end

  test "the other calls of the paused turn complete, and their results wait in the checkpoint" do
    response = paused_triage([
      self.class.tool_use("call_1", "lookup_order", order_id: 7),
      self.class.tool_use("call_2", "issue_refund", order_id: 7, amount: 40)
    ])

    assert_equal [ [ :lookup_order ] ], RefundAgent.calls
    assert_equal({ "call_1" => { "order_id" => 7, "total" => 40 } }, response.checkpoint["completed_results"])
    assert_equal [ "call_2" ], response.input_requests.map(&:tool_call_id)
  end

  test "a completed call whose tool returned nil still counts as completed" do
    paused = paused_triage([
      self.class.tool_use("call_1", "close_ticket"),
      self.class.tool_use("call_2", "issue_refund", order_id: 7, amount: 40)
    ])

    assert_equal({ "call_1" => nil }, paused.checkpoint["completed_results"])

    resume(paused, "call_2" => true)

    assert_equal [ [ :close_ticket ], [ :issue_refund, true ] ], RefundAgent.calls
    assert_equal "null", ScriptedProvider.requests.last.last[:content].first[:content]
  end

  test "the paused conversation ends with the turn that made the tool calls" do
    response = paused_triage([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])

    messages = response.checkpoint["messages"]
    assert_equal %w[user assistant], messages.map { _1["role"] }
    assert_equal "call_1", messages.last["content"].sole["id"]
    assert_equal "assistant", response.message.role.to_s, "no partial tool result follows the tool-call turn"
  end

  test "the checkpoint survives a JSON round trip unchanged" do
    response = paused_triage([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])

    checkpoint = response.checkpoint
    assert_equal checkpoint, JSON.parse(checkpoint.to_json)
    assert_equal({ "version" => 1, "service" => "Mock", "provider" => "Mock", "model" => "mock-model", "action_name" => "triage", "tool_turns" => 1 },
                 checkpoint.slice("version", "service", "provider", "model", "action_name", "tool_turns"))
  end

  test "pausing announces input_requested.active_agent with the requests" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe("input_requested.active_agent") { |*, payload| events << payload }

    paused_triage([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])

    assert_equal [ "call_1" ], events.sole[:input_requests].map(&:tool_call_id)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  test "on_input_request callbacks receive the paused response" do
    seen = []
    agent_class = Class.new(RefundAgent) do
      def self.name = "CallbackRefundAgent"

      on_input_request { |response| seen << [ :block, response.input_requests.map(&:tool_name) ] }
      on_input_request :note_pause
      on_input_request { seen << :no_argument }

      define_method(:note_pause) { |response| seen << [ :method, response.awaiting_input? ] }
    end

    ScriptedProvider.script([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])
    agent_class.triage(order_id: 7).generate_now

    assert_equal [ [ :block, [ "issue_refund" ] ], [ :method, true ], :no_argument ], seen
  end

  test "on_input_request adds no action and leaves the release digest unchanged" do
    build = lambda do |&body|
      Class.new(ApplicationAgent) do
        def self.name = "DigestedAgent"

        generate_with :mock, model: "mock-model"

        def triage = prompt(message: "Triage")

        class_eval(&body) if body
      end
    end

    plain  = build.call
    asking = build.call do
      on_input_request :notify_reviewer
      on_input_request { |response| response }

      private

      def notify_reviewer(response) = response
    end

    assert_equal [ "triage" ], asking.action_methods.to_a
    assert_equal plain.release_digest, asking.release_digest
  end

  test "on_input_request only: and except: name the generation's action, not the tool that paused it" do
    seen = []
    agent_class = Class.new(RefundAgent) do
      def self.name = "ScopedCallbackRefundAgent"

      on_input_request(only: :triage) { seen << [ :only, action_name ] }
      on_input_request(except: :triage) { seen << :except }
    end

    ScriptedProvider.script([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])
    agent_class.triage(order_id: 7).generate_now

    assert_equal [ [ :only, "triage" ] ], seen
  end

  test "on_input_request callbacks do not run for a generation that finishes" do
    seen = []
    agent_class = Class.new(RefundAgent) do
      def self.name = "QuietRefundAgent"

      on_input_request { seen << :paused }
    end

    ScriptedProvider.script([ { type: "text", text: "Nothing to do." } ])
    response = agent_class.triage(order_id: 7).generate_now

    assert_not response.awaiting_input?
    assert_nil response.checkpoint
    assert_empty seen
  end

  ##### Resuming ############################################################

  test "an approved confirmation runs the tool, and every result goes back in call order" do
    paused = paused_triage([
      self.class.tool_use("call_1", "lookup_order", order_id: 7),
      self.class.tool_use("call_2", "issue_refund", order_id: 7, amount: 40)
    ])

    response = resume(paused, "call_2" => true)

    assert_not response.awaiting_input?
    assert_equal [ [ :lookup_order ], [ :issue_refund, true ] ], RefundAgent.calls, "the completed call does not run again"

    sent = ScriptedProvider.requests.last
    assert_equal %w[user assistant user], sent.map { _1[:role].to_s }
    assert_equal [ [ "call_1", { order_id: 7, total: 40 }.to_json ], [ "call_2", { refunded: 40 }.to_json ] ],
                 sent.last[:content].map { [ _1[:tool_use_id], _1[:content] ] }
  end

  test "the generation that paused can resume itself" do
    ScriptedProvider.script([
      self.class.tool_use("call_1", "lookup_order", order_id: 7),
      self.class.tool_use("call_2", "issue_refund", order_id: 7, amount: 40)
    ])
    generation = RefundAgent.triage(order_id: 7)
    paused     = generation.generate_now

    response = generation.resume_now(checkpoint: paused.checkpoint, answers: { "call_2" => true })

    assert_not response.awaiting_input?
    assert_equal [ [ :lookup_order ], [ :issue_refund, true ] ], RefundAgent.calls
  end

  test "resuming replaces the conversation rather than adding the action's message to it" do
    paused = paused_triage([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])

    resume(paused, "call_1" => true)

    first_turn = ScriptedProvider.requests.last.first
    assert_equal "Handle order 7", first_turn[:content]
    assert_equal 3, ScriptedProvider.requests.last.size
  end

  test "a declined request skips the tool and tells the model the user declined" do
    paused = paused_triage([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])

    resume(paused, "call_1" => false)

    assert_empty RefundAgent.calls
    assert_equal ActiveAgent::InputRequest::DECLINED_RESULT.to_json, ScriptedProvider.requests.last.last[:content].sole[:content]
  end

  test "a text answer reaches the tool, which may ask again and pause once more" do
    paused = paused_triage([
      self.class.tool_use("call_1", "lookup_order", order_id: 7),
      self.class.tool_use("call_2", "ask_reason")
    ])

    again = resume(paused, "call_2" => "escalate")

    assert again.awaiting_input?
    assert_equal :choice, again.input_requests.sole.kind
    assert_equal %w[billing shipping], again.input_requests.sole.options
    assert_equal paused.checkpoint["completed_results"], again.checkpoint["completed_results"]
    assert_equal 1, ScriptedProvider.requests.size, "pausing again sends nothing to the model"

    finished = resume(again, "call_2" => "billing")

    assert_not finished.awaiting_input?
    assert_equal [ [ :lookup_order ], [ :ask_reason, "billing" ] ], RefundAgent.calls
  end

  test "a later turn can pause again, and its checkpoint holds the whole conversation" do
    paused = paused_triage(
      [ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ],
      [ self.class.tool_use("call_2", "ask_reason") ]
    )

    again = resume(paused, "call_1" => true)

    assert again.awaiting_input?
    assert_equal [ "call_2" ], again.input_requests.map(&:tool_call_id)
    assert_equal 2, again.checkpoint["tool_turns"]
    assert_equal %w[user assistant user assistant], again.checkpoint["messages"].map { _1["role"] }
    assert_empty again.checkpoint["completed_results"]

    finished = resume(again, "call_2" => "damaged in transit")

    assert_not finished.awaiting_input?
    assert_equal [ [ :issue_refund, true ], [ :ask_reason, "damaged in transit" ] ], RefundAgent.calls
    assert_equal %w[user assistant user assistant user], ScriptedProvider.requests.last.map { _1[:role].to_s }
  end

  test "the answer is readable only while its own call runs" do
    paused = paused_triage([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])

    resume(paused, "call_1" => true)

    assert_nil ActiveAgent::InputRequest.current_tool_call_id
    assert_nil ActiveAgent::InputRequest.answer_for("call_1")
  end

  test "resuming? is true while the paused generation continues" do
    observed = []
    agent_class = Class.new(RefundAgent) do
      def self.name = "ObservedRefundAgent"

      before_prompt { observed << resuming? }
    end

    ScriptedProvider.script([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])
    paused = agent_class.triage(order_id: 7).generate_now
    agent_class.triage(order_id: 7).resume_now(checkpoint: paused.checkpoint, answers: { "call_1" => true })

    assert_equal [ false, true ], observed
  end

  test "the tool-turn count carries over the pause" do
    agent_class = Class.new(RefundAgent) do
      def self.name = "CappedRefundAgent"

      def triage(order_id:)
        prompt(message: "Handle order #{order_id}", max_tool_turns: 1)
      end
    end

    ScriptedProvider.script(
      [ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ],
      [ self.class.tool_use("call_2", "lookup_order", order_id: 7) ]
    )
    paused = agent_class.triage(order_id: 7).generate_now
    agent_class.triage(order_id: 7).resume_now(checkpoint: paused.checkpoint, answers: { "call_1" => true })

    assert_equal [ [ :issue_refund, true ] ], RefundAgent.calls, "the second turn's call is over the cap"
  end

  ##### Approvals ###########################################################

  # Lists tools in requires_approval:, so their calls wait for the user.
  class GatedRefundAgent < RefundAgent
    def self.name = "GatedRefundAgent"

    def triage(order_id:)
      super
      prompt(requires_approval: %w[lookup_order deploy])
    end
  end

  def gated_triage(*turns)
    ScriptedProvider.script(*turns)
    GatedRefundAgent.triage(order_id: 7).generate_now
  end

  def resume_gated(response, answers)
    GatedRefundAgent.triage(order_id: 7).resume_now(checkpoint: JSON.parse(response.checkpoint.to_json), answers:)
  end

  test "requires_approval: pauses a listed tool before it runs, with the call's arguments" do
    paused = gated_triage([ self.class.tool_use("call_1", "lookup_order", order_id: 7) ])

    request = paused.input_requests.sole
    assert_equal [ :confirm, "lookup_order", { "order_id" => 7 }, { "approval" => true } ],
                 [ request.kind, request.tool_name, request.arguments, request.metadata ]
    assert_empty RefundAgent.calls
  end

  # Takes its approval list from params, so a test can pass any value.
  class ParamGatedRefundAgent < RefundAgent
    def self.name = "ParamGatedRefundAgent"

    def triage(order_id:)
      super
      prompt(requires_approval: params[:requires_approval])
    end
  end

  test "requires_approval: takes a single tool name, and refuses a value that is not tool names" do
    ScriptedProvider.script([ self.class.tool_use("call_1", "lookup_order", order_id: 7) ])
    paused = ParamGatedRefundAgent.with(requires_approval: :lookup_order).triage(order_id: 7).generate_now
    assert_equal "lookup_order", paused.input_requests.sole.tool_name

    [ true, { lookup_order: true }, [ "lookup_order", true ] ].each do |value|
      ScriptedProvider.script
      error = assert_raises(ArgumentError) { ParamGatedRefundAgent.with(requires_approval: value).triage(order_id: 7).generate_now }

      assert_match "requires_approval: takes a tool name or an array of tool names", error.message
      assert_empty ScriptedProvider.requests, "#{value.inspect} is refused before any request"
    end
  end

  test "an approved call runs once, and a declined one never runs" do
    paused = gated_triage([ self.class.tool_use("call_1", "lookup_order", order_id: 7), self.class.tool_use("call_2", "close_ticket") ])
    assert_equal [ [ :close_ticket ] ], RefundAgent.calls, "a tool that is not listed runs as usual"

    resume_gated(paused, "call_1" => true)
    assert_equal [ [ :close_ticket ], [ :lookup_order ] ], RefundAgent.calls

    resume_gated(paused, "call_1" => false)
    assert_equal [ [ :close_ticket ], [ :lookup_order ] ], RefundAgent.calls
    assert_equal ActiveAgent::InputRequest::DECLINED_RESULT.to_json, ScriptedProvider.requests.last.last[:content].first[:content]
  end

  test "an approved tool asks its own question without being asked to approve it again" do
    paused = gated_triage([ self.class.tool_use("call_1", "deploy", environment: "staging") ])

    asking = resume_gated(paused, "call_1" => true)

    assert_equal :secret, asking.input_requests.sole.kind, "the approval is not the tool's answer"
    assert_equal [ "call_1" ], asking.checkpoint["approved_tool_calls"]

    resume_gated(asking, "call_1" => "tok-live-12345")

    assert_equal [ [ :deploy ] ], RefundAgent.calls
  end

  test "an approval answers the gate even when the resumed action no longer requires it" do
    paused = gated_triage([ self.class.tool_use("call_1", "deploy", environment: "staging") ])
    assert_equal [ "call_1" ], paused.checkpoint["approval_tool_calls"]

    asking = resume(paused, "call_1" => true)

    assert_equal :secret, asking.input_requests.sole.kind, "the approval is not handed to the tool as its answer"
    assert_empty RefundAgent.calls
  end

  ##### Secrets #############################################################

  test "a secret answer reaches the tool but never the model" do
    paused = paused_triage([ self.class.tool_use("call_1", "deploy", environment: "staging") ])

    resume(paused, "call_1" => "tok-live-12345")

    assert_equal [ [ :deploy ] ], RefundAgent.calls
    sent = ScriptedProvider.requests.last.last[:content].sole[:content]
    assert_includes sent, "used token #{ActiveAgent::InputRequest::FILTERED}"
    assert_not_includes ScriptedProvider.requests.to_json, "tok-live-12345"
  end

  test "a secret answer is scrubbed from a tool's error" do
    paused = paused_triage([ self.class.tool_use("call_1", "deploy", environment: "broken") ])

    error = assert_raises(ArgumentError) { resume(paused, "call_1" => "tok-live-12345") }

    assert_equal "token #{ActiveAgent::InputRequest::FILTERED} was rejected", error.message
    assert_nil error.cause
  end

  # Records what the telemetry tool wrapper writes to a span.
  class SpanDouble
    attr_reader :attributes, :children, :errors

    def initialize
      @attributes = {}
      @children   = []
      @errors     = []
    end

    def add_span(_name, span_type: nil) = SpanDouble.new.tap { children << _1 }
    def set_attribute(key, value) = attributes[key] = value
    def set_tokens(**) = nil
    def set_status(*) = nil
    def record_error(error) = errors << error.message
    def finish = nil
  end

  # Prepends the telemetry wrapper unless an earlier test installed it on
  # ActiveAgent::Base, where a second copy would trace every call twice.
  def traced(agent_class)
    instrumentation = ActiveAgent::Telemetry::Instrumentation::GenerationInstrumentation
    agent_class.prepend(instrumentation) unless agent_class <= instrumentation
    agent_class
  end

  test "a secret answer is scrubbed from the tool span's arguments, result and error" do
    config = ActiveAgent::Telemetry.configuration
    saved  = [ config.enabled, config.api_key, config.capture_bodies ]
    config.enabled, config.api_key, config.capture_bodies = true, "test-key", true

    agent_class = traced(Class.new(RefundAgent) { def self.name = "TracedRefundAgent" })
    agent = agent_class.new
    agent.send(:input_request_secrets) << "tok-live-12345"
    parent = SpanDouble.new
    agent.instance_variable_set(:@_telemetry_llm_span, parent)

    ActiveAgent::InputRequest.dispatching("call_1", answer: "tok-live-12345") do
      agent.tools_function.call("deploy", environment: "tok-live-12345")
      assert_raises(ArgumentError) { agent.tools_function.call("deploy", environment: "broken") }
    end

    recorded = parent.children.map { [ _1.attributes, _1.errors ] }
    assert_equal({ environment: ActiveAgent::InputRequest::FILTERED }.to_json, recorded.first.first["tool.input.args"])
    assert_includes recorded.first.first["tool.output.result"], "used token #{ActiveAgent::InputRequest::FILTERED}"
    assert_equal [ "token #{ActiveAgent::InputRequest::FILTERED} was rejected" ], recorded.last.last
    assert_not_includes recorded.to_s, "tok-live-12345"
  ensure
    config.enabled, config.api_key, config.capture_bodies = saved if saved
  end

  test "telemetry marks the root span of a paused generation as awaiting input" do
    config = ActiveAgent::Telemetry.configuration
    saved  = [ config.enabled, config.api_key ]
    config.enabled, config.api_key = true, "test-key"

    agent_class = traced(Class.new(RefundAgent) { def self.name = "TracedPauseRefundAgent" })
    roots = []
    trace = ->(_name, **_options, &block) { block.call(SpanDouble.new.tap { roots << _1 }) }

    ActiveAgent::Telemetry.stub(:trace, trace) do
      ScriptedProvider.script([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])
      agent_class.triage(order_id: 7).generate_now

      ScriptedProvider.script([ { type: "text", text: "Nothing to refund." } ])
      agent_class.triage(order_id: 7).generate_now
    end

    assert_equal [ true, nil ], roots.map { _1.attributes["agent.awaiting_input"] }
  ensure
    config.enabled, config.api_key = saved if saved
  end

  ##### Resuming later ######################################################

  # Records the params and actor its tool runs with.
  class TicketRefundAgent < RefundAgent
    def self.name = "InputRequestsTest::TicketRefundAgent"

    def issue_refund(order_id:, amount:)
      result = super
      record(:context, params[:ticket], current_user) unless result.is_a?(ActiveAgent::InputRequest)
      result
    end
  end

  test "resume_later enqueues the resume with its params and actor, and the job continues the generation" do
    ScriptedProvider.script([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])
    paused = TicketRefundAgent.with(ticket: 42).as("user-1").triage(order_id: 7).generate_now

    TicketRefundAgent.with(ticket: 42).as("user-1").triage(order_id: 7)
                     .resume_later(checkpoint: paused.checkpoint, answers: { "call_1" => true }, queue: :refunds)

    job = enqueued_jobs.sole
    arguments = ActiveJob::Arguments.deserialize(job[:args]).last
    assert_equal "refunds", job[:queue]
    assert_equal({ "checkpoint" => paused.checkpoint, "answers" => { "call_1" => true } }, arguments[:resume])

    perform_enqueued_jobs

    assert_equal [ [ :issue_refund, true ], [ :context, 42, "user-1" ] ], RefundAgent.calls
    assert_equal "call_1", ScriptedProvider.requests.last.last[:content].sole[:tool_use_id]
  end

  test "resume_later refuses a secret answer before enqueueing" do
    ScriptedProvider.script([ self.class.tool_use("call_1", "deploy", environment: "staging") ])
    paused = RefundAgent.triage(order_id: 7).generate_now

    error = assert_raises(ActiveAgent::InputRequest::ResumeError) do
      RefundAgent.triage(order_id: 7).resume_later(checkpoint: paused.checkpoint, answers: { "call_1" => "tok-live-12345" })
    end

    assert_no_match "tok-live-12345", error.message
    assert_no_enqueued_jobs
  end

  test "resume_later refuses answers that do not fit before enqueueing" do
    paused = paused_triage([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])

    assert_raises(ActiveAgent::InputRequest::ResumeError) do
      RefundAgent.triage(order_id: 7).resume_later(checkpoint: paused.checkpoint, answers: {})
    end
    assert_no_enqueued_jobs
  end

  test "resume_later continues a direct prompt, which has no action to run again" do
    ScriptedProvider.script([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])
    paused = RefundAgent.prompt(message: "Handle order 7").generate_now
    assert paused.awaiting_input?

    RefundAgent.prompt(message: "Handle order 7").resume_later(checkpoint: paused.checkpoint, answers: { "call_1" => true })
    perform_enqueued_jobs

    assert_equal [ [ :issue_refund, true ] ], RefundAgent.calls
    assert_equal [ "Handle order 7" ], ScriptedProvider.requests.last.select { _1[:role] == "user" && _1[:content].is_a?(String) }.pluck(:content)
  end

  test "resume_later from the generation that paused raises, as generate_later does after the agent was used" do
    generation = RefundAgent.triage(order_id: 7)
    ScriptedProvider.script([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])
    paused = generation.generate_now

    assert_raises(RuntimeError) { generation.resume_later(checkpoint: paused.checkpoint, answers: { "call_1" => true }) }
    assert_no_enqueued_jobs
  end

  ##### Refusals ############################################################

  test "a missing answer raises before any tool runs or any request is sent" do
    paused = paused_triage([
      self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40),
      self.class.tool_use("call_2", "ask_reason")
    ])

    error = assert_raises(ActiveAgent::InputRequest::ResumeError) { resume(paused, "call_1" => true) }

    assert_match(/Missing answers for call_2/, error.message)
    assert_empty RefundAgent.calls
    assert_equal 1, ScriptedProvider.requests.size
  end

  test "an answer for a call that is not waiting is refused" do
    paused = paused_triage([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])

    assert_raises(ActiveAgent::InputRequest::ResumeError) { resume(paused, "call_1" => true, "call_9" => "x") }
  end

  test "a confirmation takes true or false, and a choice one of its options" do
    confirm = paused_triage([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])
    assert_raises(ActiveAgent::InputRequest::ResumeError) { resume(confirm, "call_1" => "yes") }

    text   = paused_triage([ self.class.tool_use("call_1", "ask_reason") ])
    choice = resume(text, "call_1" => "escalate")
    assert_raises(ActiveAgent::InputRequest::ResumeError) { resume(choice, "call_1" => "legal") }
  end

  test "a checkpoint resumes only the action that paused" do
    paused = paused_triage([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])

    agent_class = Class.new(RefundAgent) do
      def self.name = "OtherRefundAgent"

      def review(order_id:) = prompt(message: "Review #{order_id}")
    end

    error = assert_raises(ActiveAgent::InputRequest::ResumeError) do
      agent_class.review(order_id: 7).resume_now(checkpoint: paused.checkpoint, answers: { "call_1" => true })
    end
    assert_match(/triage/, error.message)
  end

  test "a checkpoint resumes only on the provider and model that paused" do
    paused = paused_triage([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])

    checkpoint = paused.checkpoint.merge("model" => "another-model")
    error = assert_raises(ActiveAgent::InputRequest::ResumeError) do
      RefundAgent.triage(order_id: 7).resume_now(checkpoint:, answers: { "call_1" => true })
    end
    assert_match(/another-model/, error.message)

    checkpoint = paused.checkpoint.merge("provider" => "Anthropic", "service" => "Anthropic")
    assert_raises(ActiveAgent::InputRequest::ResumeError) do
      RefundAgent.triage(order_id: 7).resume_now(checkpoint:, answers: { "call_1" => true })
    end
    assert_empty RefundAgent.calls
  end

  test "a provider that cannot pause raises instead of sending the request to the model" do
    agent_class = Class.new(RefundAgent) do
      def self.name = "UnpausableRefundAgent"

      self._prompt_provider_klass = UnpausableProvider
    end

    ScriptedProvider.script([ self.class.tool_use("call_1", "issue_refund", order_id: 7, amount: 40) ])

    error = assert_raises(ActiveAgent::InputRequest::UnsupportedProviderError) { agent_class.triage(order_id: 7).generate_now }
    assert_match(/cannot pause/, error.message)
    assert_kind_of StandardError, error, "rescue_from handlers, telemetry and job retries rescue StandardError"
  end

  ##### Delegation ##########################################################

  class ApprovalAgent < ApplicationAgent
    generate_with :mock, model: "mock-model"
    self._prompt_provider_klass = ScriptedProvider

    class_attribute :paused, default: []

    on_input_request { |response| paused << response.input_requests.map(&:tool_call_id) }

    delegation :approve, description: "Get a refund approved" do
      integer :amount, required: true
    end

    def approve(amount:)
      prompt(message: "Approve #{amount}")
    end

    def issue_refund(amount:)
      ActiveAgent::InputRequest.confirm("Refund #{amount}?")
    end
  end

  class ManagerAgent < ApplicationAgent
    generate_with :mock, model: "mock-model"
    self._prompt_provider_klass = ScriptedProvider

    delegate_to ApprovalAgent

    def handle
      prompt(message: "Handle the refund")
    end
  end

  test "a delegated agent that pauses returns a structured error to its caller" do
    ScriptedProvider.script(
      [ self.class.tool_use("call_parent", "approve", amount: 40) ],
      [ self.class.tool_use("call_child", "issue_refund", amount: 40) ]
    )

    response = ManagerAgent.handle.generate_now

    assert_not response.awaiting_input?, "the parent carries on"
    result = JSON.parse(ScriptedProvider.requests.last.last[:content].sole[:content])
    assert_equal "input_required", result["error"]
    assert_equal [ "Refund 40?" ], result["questions"]
  end

  test "a delegated agent that pauses raises under the :raise budget policy" do
    manager = Class.new(ManagerAgent) do
      def self.name = "RaisingManagerAgent"

      delegate_to ApprovalAgent, budget: { on_exceeded: :raise }
    end
    ScriptedProvider.script(
      [ self.class.tool_use("call_parent", "approve", amount: 40) ],
      [ self.class.tool_use("call_child", "issue_refund", amount: 40) ]
    )

    error = assert_raises(ActiveAgent::Delegation::InputRequiredError) { manager.handle.generate_now }

    assert_match "issue_refund", error.message
  end

  test "a delegated agent's pause is neither announced nor passed to its callbacks" do
    ApprovalAgent.paused = []
    events = []
    subscription = ActiveSupport::Notifications.subscribe("input_requested.active_agent") { |*, payload| events << payload }
    ScriptedProvider.script(
      [ self.class.tool_use("call_parent", "approve", amount: 40) ],
      [ self.class.tool_use("call_child", "issue_refund", amount: 40) ]
    )

    ManagerAgent.handle.generate_now

    assert_empty events, "a delegated pause is not announced"
    assert_empty ApprovalAgent.paused

    ScriptedProvider.script([ self.class.tool_use("call_child", "issue_refund", amount: 40) ])
    ApprovalAgent.approve(amount: 40).generate_now

    assert_equal [ [ "call_child" ] ], ApprovalAgent.paused, "the same agent run on its own runs its callbacks"
    assert_equal 1, events.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end
end
