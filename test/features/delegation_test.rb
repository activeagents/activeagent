# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/active_agent/providers/mock_provider"

# Agent-as-tool delegation: a sub-agent declares a contract, a parent exposes
# it to its model as a tool, and every call runs under a budget on a
# swappable backend.
class DelegationTest < ActiveSupport::TestCase
  ##### Test doubles ########################################################

  # A fake model that emits a scripted batch of tool calls on its first
  # response, then answers normally. This is the real provider tool loop —
  # BaseProvider#process_prompt_finished routing through +tools_function+ —
  # so delegated calls are exercised end to end without a network round trip.
  class ScriptedProvider < ActiveAgent::Providers::MockProvider
    # Type resolution derives from the class name; keep the Mock identity.
    def self.name = "ActiveAgent::Providers::MockProvider"

    class << self
      # @return [Array<Array(String, Hash)>] tool calls the fake model emits
      attr_accessor :tool_calls
      # @return [Array] results the tools returned, in call order
      attr_accessor :results

      def script(*calls)
        self.tool_calls = calls
        self.results    = []
      end
    end

    def process_prompt_finished_extract_function_calls
      return nil if @emitted

      @emitted = true
      Array(self.class.tool_calls).map { |name, arguments| { name: name.to_s, input: arguments } }
    end

    def process_function_calls(function_calls)
      function_calls.each do |function_call|
        result = tools_function.call(function_call[:name], **function_call[:input])
        self.class.results << result

        message_stack.push({ role: "user", content: result.to_json })
      end
    end
  end

  # A fake model that answers with a fixed JSON payload, so structured
  # +returns+ contracts can be exercised.
  class JsonProvider < ActiveAgent::Providers::MockProvider
    def self.name = "ActiveAgent::Providers::MockProvider"

    class << self
      # @return [Hash] payload the fake model answers with
      attr_accessor :payload
      # @return [Array<Hash>] response_format each request carried
      attr_accessor :response_formats
      # @return [Array<Hash>] full parameters each request carried
      attr_accessor :requests
    end

    def api_prompt_execute(parameters)
      self.class.response_formats << parameters[:response_format]
      self.class.requests << parameters

      super.merge("content" => [ { "type" => "text", "text" => self.class.payload.to_json } ])
    end
  end

  # A fake model that never answers in time.
  class SlowProvider < ActiveAgent::Providers::MockProvider
    def self.name = "ActiveAgent::Providers::MockProvider"

    def api_prompt_execute(parameters)
      sleep 5
      super
    end
  end

  ##### Agents ##############################################################

  class SummarizerAgent < ApplicationAgent
    generate_with :mock, model: "mock-model"

    delegation :summarize, description: "Condense a document into key points" do
      string  :text, required: true, description: "Full document text"
      integer :limit, description: "Maximum number of key points to return"
    end

    delegation :outline, description: "Produce a section outline for a document" do
      string :text, required: true, description: "Full document text"
    end

    def summarize(text:, limit: 5)
      prompt(message: "Summarize in #{limit} points: #{text}")
    end

    def outline(text:)
      prompt(message: "Outline: #{text}")
    end
  end

  class ExtractorAgent < ApplicationAgent
    generate_with :mock, model: "mock-model"

    delegation :extract, description: "Extract the contact details from a document" do
      string :text, required: true, description: "Document text"

      returns do
        string :name, required: true, description: "Full name"
        string :email, required: true, description: "Email address"
      end
    end

    def extract(text:)
      prompt(message: text)
    end
  end

  class UndeclaredAgent < ApplicationAgent
    generate_with :mock, model: "mock-model"

    def classify(body:)
      prompt(message: body)
    end
  end

  class ResearchAgent < ApplicationAgent
    generate_with :mock, model: "mock-model"

    delegate_to SummarizerAgent

    def research
      prompt(message: "Research the topic")
    end
  end

  ##### Contracts and schemas ###############################################

  test "a declared contract becomes a tool the calling model can see" do
    tool = ResearchAgent.delegated_tools.find { |candidate| candidate[:name] == "summarize" }

    assert_equal "Condense a document into key points", tool[:description]
    assert_equal "object", tool[:parameters][:type]
    assert_equal({ type: "string", description: "Full document text" }, tool[:parameters][:properties][:text])
    assert_equal "integer", tool[:parameters][:properties][:limit][:type]
    assert_equal [ "text" ], tool[:parameters][:required]
    assert_equal false, tool[:parameters][:additionalProperties]
  end

  test "the schema DSL covers scalars, arrays and nested objects" do
    schema = ActiveAgent::Delegation::Schema.build do
      string  :query, required: true, description: "Search text"
      number  :threshold
      boolean :fuzzy
      array   :tags, of: :string, description: "Topic tags"
      array   :people do
        string :name, required: true
      end
      object :filters do
        string :status, description: "Ticket status"
      end
    end

    json = schema.to_json_schema

    assert_equal "number",  json[:properties][:threshold][:type]
    assert_equal "boolean", json[:properties][:fuzzy][:type]
    assert_equal({ type: "string" }, json[:properties][:tags][:items])
    assert_equal "object", json[:properties][:people][:items][:type]
    assert_equal [ "name" ], json[:properties][:people][:items][:required]
    assert_equal "string", json[:properties][:filters][:properties][:status][:type]
    assert_equal [ "query" ], json[:required]
  end

  test "a schema can be built from a plain JSON Schema hash" do
    schema = ActiveAgent::Delegation::Schema.build(
      type: "object",
      properties: { locale: { type: "string" } },
      required: [ "locale" ]
    )

    assert_equal [ :locale ], schema.keys
    assert_equal [ :locale ], schema.required_keys
  end

  test "a schema can be built from any class that generates one" do
    model = Class.new do
      def self.to_json_schema
        { type: "object", properties: { subject: { type: "string" } }, required: [ "subject" ] }
      end
    end

    assert_equal [ :subject ], ActiveAgent::Delegation::Schema.build(model).required_keys
  end

  test "a contract without a description is refused" do
    error = assert_raises(ArgumentError) do
      Class.new(ApplicationAgent) { delegation :summarize, description: "" }
    end

    assert_match(/description/, error.message)
  end

  ##### delegate_to #########################################################

  test "delegating exposes every contract the sub-agent declares" do
    agent = Class.new(ApplicationAgent) { delegate_to SummarizerAgent }

    assert_equal [ :summarize, :outline ], agent.delegations.keys
  end

  test "only: and except: narrow what is exposed" do
    only   = Class.new(ApplicationAgent) { delegate_to SummarizerAgent, only: :summarize }
    except = Class.new(ApplicationAgent) { delegate_to SummarizerAgent, except: :outline }

    assert_equal [ :summarize ], only.delegations.keys
    assert_equal [ :summarize ], except.delegations.keys
  end

  test "as: renames the tool the model sees" do
    agent = Class.new(ApplicationAgent) { delegate_to SummarizerAgent, only: :summarize, as: :condense }

    assert_equal [ :condense ], agent.delegations.keys
    assert_equal :summarize, agent.delegations[:condense].action
    assert_equal "condense", agent.delegated_tools.first[:name]
  end

  test "a contract can be declared at the call site for an agent you do not own" do
    agent = Class.new(ApplicationAgent) do
      delegate_to UndeclaredAgent, action: :classify, description: "Classify a support ticket" do
        string :body, required: true, description: "Ticket body"
      end
    end

    tool = agent.delegated_tools.first

    assert_equal "classify", tool[:name]
    assert_equal "Classify a support ticket", tool[:description]
    assert_equal [ "body" ], tool[:parameters][:required]
  end

  test "delegating to an agent with no contracts explains how to declare one" do
    error = assert_raises(ArgumentError) { Class.new(ApplicationAgent) { delegate_to UndeclaredAgent } }

    assert_match(/does not declare any delegations/, error.message)
    assert_match(/delegate_to .*action: :action_name/, error.message)
  end

  test "delegating to an action the sub-agent does not define is refused" do
    error = assert_raises(ArgumentError) do
      Class.new(ApplicationAgent) { delegate_to UndeclaredAgent, action: :nope, description: "Nope" }
    end

    assert_match(/does not define #nope/, error.message)
  end

  test "delegating to something that is not an agent is refused" do
    error = assert_raises(ArgumentError) { Class.new(ApplicationAgent) { delegate_to String } }

    assert_match(/expects an ActiveAgent::Base subclass/, error.message)
  end

  test "a tool name that collides with an existing method is refused" do
    error = assert_raises(ArgumentError) do
      Class.new(ApplicationAgent) do
        def summarize(*) = nil
        delegate_to SummarizerAgent, only: :summarize
      end
    end

    assert_match(/already responds to #summarize/, error.message)
    assert_match(/Rename it with `as:`/, error.message)
  end

  test "as: is refused when it would rename more than one delegation" do
    error = assert_raises(ArgumentError) { Class.new(ApplicationAgent) { delegate_to SummarizerAgent, as: :thing } }

    assert_match(/Narrow it with `only:`/, error.message)
  end

  test "only: with an undeclared action lists what is available" do
    error = assert_raises(ArgumentError) { Class.new(ApplicationAgent) { delegate_to SummarizerAgent, only: :ghost } }

    assert_match(/does not declare delegation ghost/, error.message)
    assert_match(/It declares: summarize, outline/, error.message)
  end

  ##### Prompt wiring #######################################################

  test "delegated tools reach the provider alongside the action's own tools" do
    agent_class = Class.new(ApplicationAgent) do
      generate_with :mock, model: "mock-model"
      delegate_to SummarizerAgent, only: :summarize

      def research
        prompt(message: "go", tools: [ { name: "search", description: "Search", parameters: { type: "object", properties: {} } } ])
      end
    end

    parameters = prepared_parameters(agent_class, :research)

    assert_equal %w[search summarize], parameters[:tools].map { |tool| tool[:name] }
  end

  test "an action can opt out of delegations entirely" do
    agent_class = Class.new(ApplicationAgent) do
      generate_with :mock, model: "mock-model"
      delegate_to SummarizerAgent

      def research = prompt(message: "go", delegations: false)
    end

    assert_nil prepared_parameters(agent_class, :research)[:tools]
  end

  test "an action can scope itself to a subset of delegations" do
    agent_class = Class.new(ApplicationAgent) do
      generate_with :mock, model: "mock-model"
      delegate_to SummarizerAgent

      def research = prompt(message: "go", delegations: [ :outline ])
    end

    assert_equal %w[outline], prepared_parameters(agent_class, :research)[:tools].map { |tool| tool[:name] }
  end

  test "scoping to an unknown delegation lists what the agent delegates to" do
    agent_class = Class.new(ApplicationAgent) do
      generate_with :mock, model: "mock-model"
      delegate_to SummarizerAgent

      def research = prompt(message: "go", delegations: [ :ghost ])
    end

    error = assert_raises(ArgumentError) { prepared_parameters(agent_class, :research) }

    assert_match(/Unknown delegation: ghost/, error.message)
    assert_match(/summarize, outline/, error.message)
  end

  test "the delegations prompt option never reaches the provider" do
    agent_class = Class.new(ApplicationAgent) do
      generate_with :mock, model: "mock-model"
      delegate_to SummarizerAgent, only: :summarize

      def research = prompt(message: "go", delegations: [ :summarize ])
    end

    assert_not prepared_parameters(agent_class, :research).key?(:delegations)
  end

  ##### End-to-end delegation ###############################################

  test "the calling model's tool call runs the sub-agent and gets its answer back" do
    parent = scripted_agent([ :summarize, { text: "A long document", limit: 3 } ], delegate: SummarizerAgent)

    response = parent.research.generate_now

    assert response.message.content.present?
    assert_equal 1, ScriptedProvider.results.length
    assert_kind_of String, ScriptedProvider.results.first
    assert ScriptedProvider.results.first.present?
  end

  test "arguments the contract never declared are dropped rather than crashing the sub-agent" do
    parent = scripted_agent([ :summarize, { text: "doc", limit: 2, hallucinated: "nonsense" } ], delegate: SummarizerAgent)

    parent.research.generate_now

    assert_equal 1, ScriptedProvider.results.length
    assert_kind_of String, ScriptedProvider.results.first
  end

  test "each delegated call is recorded on the agent's ledger" do
    parent = scripted_agent(
      [ :summarize, { text: "one" } ], [ :summarize, { text: "two" } ], delegate: SummarizerAgent
    )

    agent = parent.new
    agent.process(:research)
    agent.process_prompt

    assert_equal 2, agent.delegation_ledger.calls
    assert_equal 2, agent.delegation_ledger_for(:summarize).calls
    assert_operator agent.delegation_ledger.tokens, :>, 0
    assert_operator agent.delegation_ledger.duration, :>=, 0
  end

  test "delegated calls are instrumented" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe("delegate.active_agent") { |*, payload| events << payload }

    parent = scripted_agent([ :summarize, { text: "doc" } ], delegate: SummarizerAgent)
    parent.research.generate_now

    assert_equal 1, events.length
    assert_equal "summarize", events.first[:tool]
    assert_equal :summarize, events.first[:action]
    assert_equal :ok, events.first[:status]
    assert_operator events.first[:duration_ms], :>=, 0
    assert events.first[:usage].present?
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  test "a delegated generation runs under the parent's trace id" do
    trace_ids = []
    subscription = ActiveSupport::Notifications.subscribe("prompt.active_agent") do |*, payload|
      trace_ids << payload[:trace_id]
    end

    parent = scripted_agent([ :summarize, { text: "doc" } ], delegate: SummarizerAgent)
    parent.research.generate_now

    assert_equal 1, trace_ids.compact.uniq.length, "parent and sub-agent share one trace"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  ##### Budgets #############################################################

  test "a call budget stops delegating and tells the model why" do
    parent = scripted_agent(
      [ :summarize, { text: "one" } ], [ :summarize, { text: "two" } ], [ :summarize, { text: "three" } ],
      delegate: SummarizerAgent, budget: { max_calls: 2 }
    )

    parent.research.generate_now

    refused = ScriptedProvider.results.last

    assert_equal "budget_exceeded", refused[:error]
    assert_equal "max_calls", refused[:limit]
    assert_equal 2, refused[:allowed]
    assert_equal 2, refused[:used]
    assert_match(/Do not retry this tool/, refused[:message])
  end

  test "an agent-wide budget covers every delegation together" do
    parent = scripted_agent(
      [ :summarize, { text: "one" } ], [ :outline, { text: "two" } ], [ :summarize, { text: "three" } ],
      delegate: SummarizerAgent
    )
    parent.delegation_budget max_calls: 2

    parent.research.generate_now

    assert_equal "budget_exceeded", ScriptedProvider.results.last[:error]
    assert_equal 2, ScriptedProvider.results.count { |result| result.is_a?(String) }
  end

  test "a token budget stops delegating once the sub-agent has spent it" do
    parent = scripted_agent(
      [ :summarize, { text: "one" } ], [ :summarize, { text: "two" } ],
      delegate: SummarizerAgent, budget: { max_tokens: 1 }
    )

    parent.research.generate_now

    assert_kind_of String, ScriptedProvider.results.first
    assert_equal "max_tokens", ScriptedProvider.results.last[:limit]
  end

  test "a budget can be configured to raise instead of degrading" do
    parent = scripted_agent(
      [ :summarize, { text: "one" } ], [ :summarize, { text: "two" } ],
      delegate: SummarizerAgent, budget: { max_calls: 1, on_exceeded: :raise }
    )

    error = assert_raises(ActiveAgent::Delegation::BudgetExceededError) { parent.research.generate_now }

    assert_equal :max_calls, error.violation.limit
    assert_match(/exceeded its delegation budget/, error.message)
  end

  test "budgets are scoped to one generation" do
    parent = scripted_agent([ :summarize, { text: "one" } ], delegate: SummarizerAgent, budget: { max_calls: 1 })

    2.times do
      ScriptedProvider.script([ :summarize, { text: "one" } ])
      parent.research.generate_now

      assert_kind_of String, ScriptedProvider.results.first, "each generation starts with a fresh budget"
    end
  end

  test "a per-call timeout degrades into an answerable result" do
    sub = Class.new(SummarizerAgent) { self._prompt_provider_klass = SlowProvider }
    parent = scripted_agent([ :summarize, { text: "one" } ], delegate: sub, budget: { timeout: 0.1 })

    parent.research.generate_now

    timed_out = ScriptedProvider.results.first

    assert_equal "timeout", timed_out[:error]
    assert_equal 0.1, timed_out[:allowed]
    assert_match(/timed out/, timed_out[:message])
  end

  test "a timed-out call still counts against the budget" do
    sub = Class.new(SummarizerAgent) { self._prompt_provider_klass = SlowProvider }
    parent = scripted_agent([ :summarize, { text: "one" } ], delegate: sub, budget: { timeout: 0.1 })

    agent = parent.new
    agent.process(:research)
    agent.process_prompt

    assert_equal 1, agent.delegation_ledger.calls
    assert_operator agent.delegation_ledger.duration, :>=, 0.1
  end

  test "a budget rejects unknown limits and policies" do
    assert_match(/Unknown delegation budget keys: max_spend/,
      assert_raises(ArgumentError) { ActiveAgent::Delegation::Budget.build(max_spend: 1) }.message)

    assert_match(/Unknown delegation budget policy/,
      assert_raises(ArgumentError) { ActiveAgent::Delegation::Budget.build(on_exceeded: :explode) }.message)
  end

  test "a call-site budget layers over the contract's own default" do
    sub = Class.new(ApplicationAgent) do
      generate_with :mock, model: "mock-model"
      delegation :work, description: "Do work", budget: { max_calls: 9, timeout: 30 }
      def work = prompt(message: "work")
    end

    parent = Class.new(ApplicationAgent) { delegate_to sub, budget: { max_calls: 2 } }
    budget = parent.delegations[:work].budget

    assert_equal 2, budget.max_calls, "the call site knows what the work is worth"
    assert_equal 30, budget.timeout, "the contract's default survives where the call site is silent"
  end

  ##### Cost ################################################################

  test "registered rates turn token usage into a cost budget" do
    ActiveAgent::Delegation::Pricing.register("mock-model", input: 1_000_000.0, output: 1_000_000.0)

    parent = scripted_agent(
      [ :summarize, { text: "one" } ], [ :summarize, { text: "two" } ],
      delegate: SummarizerAgent, budget: { max_cost: 0.5 }
    )

    parent.research.generate_now

    assert_kind_of String, ScriptedProvider.results.first
    assert_equal "max_cost", ScriptedProvider.results.last[:limit]
  end

  test "rates can be stated inline on a budget" do
    usage = ActiveAgent::Providers::Common::Usage.new(input_tokens: 1_000_000, output_tokens: 500_000)
    cost  = ActiveAgent::Delegation::Pricing.cost_for(usage: usage, model: "unpriced", rates: { input: 0.15, output: 0.60 })

    assert_in_delta 0.45, cost, 0.0001
  end

  test "cost is nil when no rates are known, so an unpriced model never fakes a number" do
    usage = ActiveAgent::Providers::Common::Usage.new(input_tokens: 100, output_tokens: 100)

    assert_nil ActiveAgent::Delegation::Pricing.cost_for(usage: usage, model: "who-knows")
  end

  test "registered rates match by prefix and by pattern" do
    ActiveAgent::Delegation::Pricing.register("gpt-4o-mini", input: 0.15, output: 0.60)
    ActiveAgent::Delegation::Pricing.register(/\Aclaude-haiku/, input: 1.0, output: 5.0)

    assert_equal({ input: 0.15, output: 0.60 }, ActiveAgent::Delegation::Pricing.rates_for("gpt-4o-mini-2024-07-18"))
    assert_equal({ input: 1.0, output: 5.0 }, ActiveAgent::Delegation::Pricing.rates_for("claude-haiku-4-5"))
    assert_nil ActiveAgent::Delegation::Pricing.rates_for("llama3.1")
  end

  ##### Backends ############################################################

  test "a backend can swap the model without touching the sub-agent" do
    parent = scripted_agent(
      [ :summarize, { text: "one" } ], delegate: SummarizerAgent, backend: { model: "swapped-model", temperature: 0 }
    )

    parent.research.generate_now

    assert_equal "swapped-model", last_delegated_model
    assert_equal "mock-model", SummarizerAgent.prompt_options[:model], "the sub-agent's own configuration is untouched"
  end

  test "a backend can swap the provider, and the sub-agent's views still resolve" do
    parent = Class.new(ApplicationAgent) do
      generate_with :mock, model: "mock-model"
      delegate_to SummarizerAgent, only: :summarize, backend: :openai
    end

    resolved = parent.delegations[:summarize].resolved_agent_class

    assert_not_equal SummarizerAgent, resolved
    assert_operator resolved, :<, SummarizerAgent
    assert_equal "OpenAI", resolved.prompt_options[:service]
    assert_equal SummarizerAgent.name, resolved.name, "view lookup follows the class name"
    assert_equal SummarizerAgent.name.underscore, resolved.new.agent_name
    assert_equal "Mock", SummarizerAgent.prompt_options[:service], "the sub-agent's own provider is untouched"
  end

  test "the swapped class is built once and reused" do
    definition = Class.new(ApplicationAgent) do
      delegate_to SummarizerAgent, only: :summarize, backend: { provider: :openai }
    end.delegations[:summarize]

    assert_same definition.resolved_agent_class, definition.resolved_agent_class
  end

  test "an agent with no backend override runs on its own configuration" do
    definition = ResearchAgent.delegations[:summarize]

    assert_same SummarizerAgent, definition.resolved_agent_class
    assert_not definition.backend.overrides?
  end

  ##### Structured returns ##################################################

  test "a declared returns schema becomes the sub-agent's response format" do
    JsonProvider.payload           = { name: "Ada Lovelace", email: "ada@example.com" }
    JsonProvider.response_formats  = []
    JsonProvider.requests          = []

    sub    = Class.new(ExtractorAgent) { self._prompt_provider_klass = JsonProvider }
    parent = scripted_agent([ :extract, { text: "Ada Lovelace <ada@example.com>" } ], delegate: sub)

    parent.research.generate_now

    format = JsonProvider.response_formats.compact.first

    assert_equal "json_schema", format[:type].to_s
    assert_equal "extract_result", format[:json_schema][:name]
    assert_equal %w[name email], format[:json_schema][:schema][:properties].keys.map(&:to_s)
    assert_equal %w[name email], format[:json_schema][:schema][:required]
  end

  test "a structured sub-agent hands back parsed data, not a blob of text" do
    JsonProvider.payload          = { name: "Ada Lovelace", email: "ada@example.com" }
    JsonProvider.response_formats = []
    JsonProvider.requests         = []

    sub    = Class.new(ExtractorAgent) { self._prompt_provider_klass = JsonProvider }
    parent = scripted_agent([ :extract, { text: "Ada Lovelace <ada@example.com>" } ], delegate: sub)

    parent.research.generate_now

    assert_equal({ name: "Ada Lovelace", email: "ada@example.com" }, ScriptedProvider.results.first)
  end

  test "output that breaks the contract comes back as something the model can act on" do
    JsonProvider.payload          = { name: "Ada Lovelace" }
    JsonProvider.response_formats = []
    JsonProvider.requests         = []

    sub    = Class.new(ExtractorAgent) { self._prompt_provider_klass = JsonProvider }
    parent = scripted_agent([ :extract, { text: "Ada Lovelace" } ], delegate: sub)

    parent.research.generate_now

    invalid = ScriptedProvider.results.first

    assert_equal "invalid_result", invalid[:error]
    assert_equal [ "email" ], invalid[:missing]
    assert_match(/missing required key: email/, invalid[:message])
  end

  test "contract violations can be configured to raise" do
    strict = Class.new(ApplicationAgent) do
      generate_with :mock, model: "mock-model"

      delegation :extract, description: "Extract contact details", on_invalid: :raise do
        string :text, required: true, description: "Document text"
        returns { string :email, required: true, description: "Email address" }
      end

      def extract(text:) = prompt(message: text)
    end

    JsonProvider.payload          = { nope: true }
    JsonProvider.response_formats = []
    JsonProvider.requests         = []
    strict._prompt_provider_klass = JsonProvider

    parent = scripted_agent([ :extract, { text: "doc" } ], delegate: strict)

    error = assert_raises(ActiveAgent::Delegation::InvalidResultError) { parent.research.generate_now }

    assert_match(/missing required key: email/, error.message)
  end

  test "a returns schema keeps its required list consistent with the keys it emits" do
    schema = ActiveAgent::Delegation::Schema.build do
      string :max_points, required: true
    end

    format = schema.to_response_format(name: "result")

    assert_equal [ "maxPoints" ], format[:required] || format[:schema][:required]
    assert format[:strict]
  end

  ##### Params ##############################################################

  test "params can be forwarded to the sub-agent" do
    sub = Class.new(ApplicationAgent) do
      generate_with :mock, model: "mock-model"
      delegation :echo, description: "Echo the tenant" do
        string :text, required: true, description: "Text"
      end

      def echo(text:) = prompt(message: "#{params[:tenant]}: #{text}")
    end

    parent = scripted_agent([ :echo, { text: "hi" } ], delegate: sub, params: { tenant: "acme" })
    parent.research.generate_now

    assert_match(/acme/i, ScriptedProvider.results.first)
  end

  test "params can be computed from the delegating agent" do
    sub = Class.new(ApplicationAgent) do
      generate_with :mock, model: "mock-model"
      delegation :echo, description: "Echo the tenant" do
        string :text, required: true, description: "Text"
      end

      def echo(text:) = prompt(message: "#{params[:tenant]}: #{text}")
    end

    parent = scripted_agent([ :echo, { text: "hi" } ], delegate: sub, params: :tenant_params)
    parent.class_eval { define_method(:tenant_params) { { tenant: "override" } } }
    parent.research.generate_now

    assert_match(/override/i, ScriptedProvider.results.first)
  end

  private

  # Builds a delegating agent whose model emits the given tool calls.
  #
  # @param calls [Array<Array(Symbol, Hash)>]
  # @return [Class]
  def scripted_agent(*calls, delegate:, **delegation_options)
    ScriptedProvider.script(*calls)

    Class.new(ApplicationAgent) do
      generate_with :mock, model: "mock-model"
      self._prompt_provider_klass = ScriptedProvider

      delegate_to delegate, **delegation_options

      def research = prompt(message: "Research the topic")
    end
  end

  # @return [Hash] the parameters an action would send to its provider
  def prepared_parameters(agent_class, action)
    agent = agent_class.new
    agent.process(action)
    agent.send(:prepare_prompt_parameters)
  end

  # @return [String, nil] the model the most recent delegated call ran on
  def last_delegated_model
    @last_delegated_model
  end

  def setup
    ActiveAgent::Delegation::Pricing.reset!
    ScriptedProvider.script
    @delegate_events = []
    @subscription = ActiveSupport::Notifications.subscribe("delegate.active_agent") do |*, payload|
      @last_delegated_model = payload[:model]
      @delegate_events << payload
    end
  end

  def teardown
    ActiveSupport::Notifications.unsubscribe(@subscription)
    ActiveAgent::Delegation::Pricing.reset!
  end
end
