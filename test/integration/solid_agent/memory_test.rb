# frozen_string_literal: true

require_relative "integration_case"

# Defined behind a guard because the class body references a constant the
# released gem may not have: an unguarded `include` would take the whole
# suite down with a NameError instead of reporting a skip.
if SolidAgentIntegrationTest.solid_agent_const_defined?("SolidAgent::HasMemory")
  module Persistence
    class ResearcherAgent < ApplicationAgent
      include SolidAgent::HasMemory

      generate_with :mock, model: "mock-gpt-4o-mini"

      has_memory

      def research
        prompt message: params[:message], tools: memory_tool_definitions
      end

      def memory_subject
        params[:memorable]
      end
    end

    class WriterAgent < ResearcherAgent
      def draft
        prompt message: params[:message], tools: memory_tool_definitions
      end
    end
  end
end

# Memory is scoped to a subject rather than an agent class, which is what
# makes it a hand-off channel. That claim is only true if two agent classes
# genuinely read each other's notes through the host app's models.
class SolidAgentMemoryTest < SolidAgentIntegrationTest
  requires_solid_agent "SolidAgent::HasMemory"

  test "one agent's notes are readable by another working on the same subject" do
    researcher = agent(Persistence::ResearcherAgent, memorable: subject_record)
    researcher.save_memory(content: "Ships on the 14th", category: "fact")

    writer = agent(Persistence::WriterAgent, memorable: subject_record)
    recalled = writer.recall_memory

    assert_equal 1, recalled[:count]
    assert_equal "Ships on the 14th", recalled[:entries].first[:content]
    assert_equal "Persistence::ResearcherAgent", recalled[:entries].first[:source_agent],
      "expected the writing agent to be recorded as the source"
  end

  test "memory rows land in the host app's models" do
    agent(Persistence::ResearcherAgent, memorable: subject_record)
      .save_memory(content: "Pricing unchanged", category: "fact")

    memory = AgentMemory.sole

    assert_equal subject_record, memory.memorable
    assert_equal "default", memory.scope
    assert_equal [ "Pricing unchanged" ], memory.summary_list
    assert_includes memory.to_prompt, "Pricing unchanged (Persistence::ResearcherAgent)"
  end

  test "scopes keep separate streams on one subject" do
    AgentMemory.for(subject_record).remember("default stream", source_agent: "Test")
    AgentMemory.for(subject_record, scope: "planning").remember("planning stream", source_agent: "Test")

    assert_equal 2, AgentMemory.count
    assert_equal [ "default stream" ], AgentMemory.for(subject_record).summary_list
    assert_equal [ "planning stream" ], AgentMemory.for(subject_record, scope: "planning").summary_list
  end

  test "categories filter recall and missing subjects fail legibly" do
    researcher = agent(Persistence::ResearcherAgent, memorable: subject_record)
    researcher.save_memory(content: "a fact", category: "fact")
    researcher.save_memory(content: "a handoff", category: "handoff")

    assert_equal [ "a handoff" ], researcher.recall_memory(category: "handoff")[:entries].map { |e| e[:content] }

    subjectless = agent(Persistence::ResearcherAgent)

    assert_equal({ error: "No memory subject available" }, subjectless.save_memory(content: "nowhere to put it"))
    assert_equal({ error: "No memory subject available" }, subjectless.recall_memory)
  end

  test "the tool schemas the model is offered match the module-level contract" do
    definitions = agent(Persistence::ResearcherAgent, memorable: subject_record).memory_tool_definitions

    assert_equal SolidAgent::HasMemory.tool_definitions, definitions
    assert_equal %w[save_memory recall_memory], definitions.map { |tool| tool[:name] }
  end

  private

  # The provider decides when to call a tool; the mock one never does. These
  # tests drive the tool methods the way a provider would, which is the part
  # of the contract that belongs to solid_agent.
  def agent(klass, **params)
    klass.new.tap { |instance| instance.params = params }
  end
end
