# frozen_string_literal: true

require "test_helper"
require "active_agent/evals/jev"
require_relative "evals_test_support"

# The Jev judge against a real System One server: OpenJevX, run on this
# machine with `docker compose up -d --build` in its repository
# (https://github.com/muthuishere/openjevx), which serves the protocol at
# http://127.0.0.1:21118 on the CPU. Opt in with OPENJEVX_URL, so the suite
# never needs a model:
#
#   OPENJEVX_URL=http://127.0.0.1:21118 bin/test test/evals/jev_openjevx_test.rb
#
# What is checked is the shape of the judgement, never a particular number:
# a specific, complete answer grades above a refusal, and a verdict picks
# one of the compared models.
class EvalsJevOpenJevXTest < ActiveSupport::TestCase
  include EvalsTestSupport

  SUMMARIES = {
    "gpt-5-mini" => { "pass_rate" => 90.0, "avg_score" => 0.91, "avg_duration_ms" => 1200, "cost" => 0.12 },
    "ollama/qwen3:8b" => { "pass_rate" => 60.0, "avg_score" => 0.7, "avg_duration_ms" => 900, "cost" => 0.01,
                           "faults" => { "low_quality" => 2 } }
  }.freeze

  setup do
    @url = ENV["OPENJEVX_URL"].presence
    skip "set OPENJEVX_URL to a running OpenJevX server to run this test" unless @url
  end

  test "a complete answer grades above a refusal" do
    with_real_connections do
      complete = judge.score_task(
        scenario: scenario,
        answer: "Alice changed the shipping policy on Monday (policy log entry 42). Want me to show the diff?"
      )
      refusal = judge.score_task(scenario: scenario, answer: "I can't help with that.")

      assert_kind_of Float, complete
      assert_kind_of Float, refusal
      assert_operator complete, :>, refusal
    end
  end

  test "a verdict picks one of the compared models" do
    with_real_connections do
      verdict = judge.verdict(SUMMARIES, instructions: "Answer questions about orders with specific, tool-backed data.")

      assert_includes SUMMARIES.keys, verdict&.dig("winner")
      assert_match(/\AChosen by Jev with probability \d\.\d\d\.\z/, verdict["rationale"])
    end
  end

  private

  def judge
    @judge ||= ActiveAgent::Evals::Jev.judge(label: "openjevx", base_url: @url)
  end

  # The suite refuses real connections; this test is the one place one is
  # meant to happen.
  def with_real_connections
    VCR.turned_off(ignore_cassettes: true) do
      WebMock.allow_net_connect!
      yield
    ensure
      WebMock.disable_net_connect!
    end
  end
end
