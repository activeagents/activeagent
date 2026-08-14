# frozen_string_literal: true

require "test_helper"

module Docs
  module Actions
    # Worked example for the Delegation documentation.
    #
    # A support desk that triages tickets: a cheap classifier gives the ticket
    # a category, a knowledge-base agent finds the relevant article, and a
    # frontier model writes the reply. Each is its own agent with its own
    # instructions and its own model — the triage agent just calls them.
    class DelegationExamplesTest < ActiveSupport::TestCase
      # region classifier_agent
      class TicketClassifierAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o-mini"

        delegation :classify, description: "Classify a support ticket by topic and urgency" do
          string :body, required: true, description: "The customer's message, verbatim"

          returns do
            string :category, required: true, enum: %w[billing bug account other],
                              description: "What the ticket is about"
            string :urgency, required: true, enum: %w[low normal high],
                             description: "How quickly it needs a human"
          end
        end

        def classify(body:)
          prompt(message: body)
        end
      end
      # endregion classifier_agent

      # region knowledge_agent
      class KnowledgeBaseAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o-mini"

        delegation :lookup, description: "Find the help-centre article that answers a question" do
          string  :question, required: true, description: "The customer's question in plain language"
          integer :limit, description: "How many articles to consider (default 5)"
        end

        def lookup(question:, limit: 5)
          prompt(message: "Answer from the help centre, citing up to #{limit} article titles: #{question}")
        end
      end
      # endregion knowledge_agent

      # region triage_agent
      class TriageAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o"

        # Ceiling for every delegation this agent makes in one generation.
        delegation_budget max_calls: 6, max_duration: 45

        delegate_to TicketClassifierAgent, budget: { max_calls: 1, timeout: 10 }
        delegate_to KnowledgeBaseAgent, as: :search_help_centre,
                    budget: { max_calls: 3, max_tokens: 20_000 }

        def triage(ticket:)
          prompt(message: "Triage this ticket. Classify it first, then find the article that answers it.\n\n#{ticket}")
        end
      end
      # endregion triage_agent

      test "the sub-agents' declared schemas are what the triage model sees" do
        tools = TriageAgent.delegated_tools

        doc_example_output(tools)

        assert_equal %w[classify search_help_centre], tools.map { |tool| tool[:name] }
        assert_equal "Classify a support ticket by topic and urgency", tools.first[:description]
        assert_equal [ "body" ], tools.first[:parameters][:required]
        assert_equal %w[question limit], tools.last[:parameters][:properties].keys.map(&:to_s)
      end

      test "budgets layer: the agent-wide ceiling and the per-delegation limit" do
        budgets = {
          agent: TriageAgent.delegation_budget.to_h,
          classify: TriageAgent.delegations[:classify].budget.to_h,
          search_help_centre: TriageAgent.delegations[:search_help_centre].budget.to_h
        }

        doc_example_output(budgets)

        assert_equal({ max_calls: 6, max_duration: 45 }, budgets[:agent])
        assert_equal({ max_calls: 1, timeout: 10 }, budgets[:classify])
        assert_equal({ max_calls: 3, max_tokens: 20_000 }, budgets[:search_help_centre])
      end

      test "swapping a backend moves a sub-agent to another provider without editing it" do
        # region backend_swap
        class LocalTriageAgent < TriageAgent
          # Same classifier, same contract, different silicon.
          delegate_to TicketClassifierAgent, backend: { provider: :ollama, model: "gpt-oss:20b" }
        end
        # endregion backend_swap

        swapped = LocalTriageAgent.delegations[:classify].resolved_agent_class

        assert_equal "Ollama", swapped.prompt_options[:service]
        assert_equal "gpt-oss:20b", swapped.prompt_options[:model]
        assert_equal "OpenAI", TicketClassifierAgent.prompt_options[:service],
          "the classifier itself is untouched"
      end

      test "a delegation is an ordinary method, so tests can call it without a model" do
        # region testing_backend
        class TestTriageAgent < TriageAgent
          # Point the sub-agent at the mock provider; the contract is unchanged.
          delegate_to KnowledgeBaseAgent, as: :search_help_centre, backend: :mock
        end
        # endregion testing_backend

        # region testing_call
        result = TestTriageAgent.new.search_help_centre(question: "How do I reset my password?")
        # endregion testing_call

        doc_example_output(result)

        assert result.present?
        assert_kind_of String, result
      end

      test "an exhausted budget answers the model instead of raising at it" do
        capped = Class.new(TriageAgent) do
          delegate_to KnowledgeBaseAgent, as: :search_help_centre, backend: :mock,
                      budget: { max_calls: 1 }
        end
        agent = capped.new

        agent.search_help_centre(question: "How do I reset my password?")

        # region budget_exhausted
        refused = agent.search_help_centre(question: "And how do I change my email?")
        # endregion budget_exhausted

        doc_example_output(refused)

        assert_equal "budget_exceeded", refused[:error]
        assert_equal "max_calls", refused[:limit]
        assert_equal 1, agent.delegation_ledger.calls
      end
    end
  end
end
