# frozen_string_literal: true

# The evaluation module loads without the ruby_llm gem; the RubyLLM glue is an
# opt-in require on top of it, and then works without the framework.
require "active_agent/evals"

raise "the framework should not be loaded" if defined?(ActiveAgent::Base)
raise "active_agent/evals must not load ruby_llm" if defined?(::RubyLLM)

require "active_agent/evals/ruby_llm"

raise "active_agent/evals/ruby_llm should load ruby_llm" unless defined?(::RubyLLM::VERSION)

context = Object.new
def context.chat(**)
  chat = Object.new
  def chat.with_instructions(*) = self
  def chat.ask(*) = Struct.new(:content).new('{"score": 0.9}')
  chat
end

judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "m", provider: :openai, context: context)
scenario = ActiveAgent::Evals::Scenario.from_hash({ "key" => "lookup_1", "prompt" => "Where is order ABC-123?" })
score = judge.score_task(scenario: scenario, answer: "Shipped on Monday.")
raise "expected the judge's score, got #{score.inspect}" unless score == 0.9

messages = [
  ::RubyLLM::Message.new(role: :user, content: "Where is order ABC-123?"),
  ::RubyLLM::Message.new(role: :assistant, content: "Shipped on Monday.", input_tokens: 10, output_tokens: 3)
]
replay = ActiveAgent::Evals::RubyLLM.replay(messages)
raise "expected the replay answer, got #{replay.inspect}" unless replay.answer == "Shipped on Monday." && replay.total_tokens == 13

puts "ok"
