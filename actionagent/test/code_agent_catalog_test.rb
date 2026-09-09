# frozen_string_literal: true

require "test_helper"

# The catalog is the only place that says what a coding agent needs, what it
# cannot do in a sandbox and how it is driven. The dashboard renders those
# claims, CodeSessionBrief writes them into BRIEF.md and CodeOnIncusBackend
# turns headless? into either coi's --prompt-file path or a plain command —
# so an entry missing a field is a blank card and a wrong headless? is a run
# that hangs waiting for a person who is not there.
class ActionAgentCodeAgentCatalogTest < ActiveSupport::TestCase
  Catalog = ActionAgent::CodeAgentCatalog

  # Only supported_tools is asked of a backend, so this stands in for a host
  # app's own backend answering for its own image.
  ToolLimitedBackend = Struct.new(:supported_tools)

  # The two entries with neither a coi tool path nor a headless command:
  # they are started and then attached to.
  INTERACTIVE_ONLY = %w[pi omp].freeze

  test "every entry carries the fields the dashboard and the brief render" do
    Catalog.all.each do |entry|
      assert entry.key.present?, "an entry has no key"
      assert entry.name.present?, "#{entry.key} has no name"
      assert entry.vendor.present?, "#{entry.key} has no vendor"
      assert entry.credentials.present?, "#{entry.key} names no credentials"
      assert entry.needs.present?, "#{entry.key} lists no needs"
      assert entry.limitations.present?, "#{entry.key} lists no limitations"
      assert entry.credentials.all?(Array), "#{entry.key} credentials should be any-of groups"
    end
  end

  # BY_KEY indexes by key, so a duplicate would silently drop an entry from
  # every lookup while still showing up in the list.
  test "keys are unique and are what keys returns, in order" do
    keys = Catalog.all.map(&:key)

    assert_equal keys.uniq, keys
    assert_equal keys, Catalog.keys
    assert_equal "claude_code", keys.first, "the default coding agent comes first"
  end

  # coi documents `coi run --prompt-file` for the claude tool alone. Marking
  # anything else headless would send it down a path coi does not have.
  test "claude_code is the only headless entry and headless entries name a coi tool" do
    assert_equal [ "claude_code" ], Catalog.all.select(&:headless?).map(&:key)

    Catalog.all.select(&:headless?).each do |entry|
      assert entry.coi_tool.present?, "#{entry.key} is headless but names no coi tool"
      assert_not entry.experimental?, "the headless path is the supported one, so #{entry.key} is not experimental"
    end
  end

  # Anything not on coi's own headless path is driven through
  # `coi run -- <argv>` and says so in the UI, or it cannot be driven at all.
  test "a non-headless entry either has a command or is an experimental interactive-only tool" do
    Catalog.all.reject(&:headless?).each do |entry|
      if entry.headless_command.present?
        assert entry.experimental?, "#{entry.key} is driven through a plain command, so it is experimental"
        assert entry.headless_command.all?(String), "#{entry.key} command should be an argv of strings"
      else
        assert_includes INTERACTIVE_ONLY, entry.key, "#{entry.key} can neither be run nor attached to"
        assert entry.experimental?, "#{entry.key} is interactive only, so it is experimental"
        assert_match(/interactive/i, entry.limitations.join(" "), "#{entry.key} should say it is interactive only")
      end
    end
  end

  test "command_for substitutes the prompt path in every element that names it" do
    command = Catalog.find("codex").command_for("/brief/PROMPT.md")

    assert_equal [ "codex", "exec", "--full-auto", "@/brief/PROMPT.md" ], command

    Catalog.all.select { |entry| entry.headless_command.present? }.each do |entry|
      substituted = entry.command_for("/brief/PROMPT.md")

      assert_equal entry.headless_command.size, substituted.size
      assert substituted.none? { |part| part.include?("%{prompt_file}") },
        "#{entry.key} left a placeholder in #{substituted.inspect}"
      assert substituted.any? { |part| part.include?("/brief/PROMPT.md") },
        "#{entry.key} never uses the prompt file"
    end
  end

  # nil is the signal CodeOnIncusBackend#run turns into a RunError rather
  # than a command it cannot build.
  test "command_for is nil for a tool with no headless command" do
    INTERACTIVE_ONLY.each { |key| assert_nil Catalog.find(key).command_for("/brief/PROMPT.md") }

    # Claude Code is not interactive-only: it has no argv because coi runs
    # it through --prompt-file instead.
    assert_nil Catalog.find("claude_code").command_for("/brief/PROMPT.md")
    assert Catalog.find("claude_code").headless?
  end

  # The backend seeds one file per environment variable, so the any-of
  # grouping has to flatten to the plain names it writes.
  test "credential_names flattens the any-of groups to bare variable names" do
    entry = Catalog.find("claude_code")

    assert_equal [ %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN] ], entry.credentials
    assert_equal %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN], entry.credential_names

    Catalog.all.each do |candidate|
      assert candidate.credential_names.all?(String), "#{candidate.key} credential names should be flat strings"
      assert candidate.credential_names.none?(&:empty?), "#{candidate.key} has a blank credential name"
    end
  end

  test "find takes a string or a symbol and answers nil for an unknown key" do
    assert_equal "Claude Code", Catalog.find("claude_code").name
    assert_equal "Claude Code", Catalog.find(:claude_code).name
    assert_nil Catalog.find("some_agent")
    assert_nil Catalog.find(nil)
  end

  # A session whose tool the catalog lost still has to render, so the key
  # itself is the fallback name rather than nil.
  test "display_name falls back to the key it was given" do
    assert_equal "Codex CLI", Catalog.display_name("codex")
    assert_equal "some_agent", Catalog.display_name("some_agent")
  end

  test "as_json_summary carries what the tool picker shows and no credential value" do
    summary = Catalog.find("codex").as_json_summary

    assert_equal(
      %i[credentials docs_url experimental headless key limitations name needs vendor],
      summary.keys.sort
    )
    assert_equal [ %w[OPENAI_API_KEY] ], summary[:credentials], "only the variable name, never its value"
    assert summary[:experimental]
    assert_not summary[:headless]
  end

  test "supported_by asks the backend, and the mock backend supports everything" do
    assert_equal Catalog.all, Catalog.supported_by(ActionAgent::MockCodeSessionBackend.new)

    limited = Catalog.supported_by(ToolLimitedBackend.new([ "claude_code" ]))

    assert_equal [ "claude_code" ], limited.map(&:key)
  end

  # The protocol says everything but launch and run degrades rather than
  # raising, so a backend that never declared its tools gets all of them.
  test "supported_by returns every entry for a backend that does not answer" do
    assert_equal Catalog.all, Catalog.supported_by(Object.new)
    assert_equal [], Catalog.supported_by(ToolLimitedBackend.new([]))
  end

  # The coi backend runs a tool either as a coi tool or as a plain command,
  # so an entry with neither is one it cannot launch at all.
  test "the coi backend supports every entry it can actually start" do
    supported = ActionAgent::CodeOnIncusBackend.new.supported_tools

    assert_equal Catalog.all.reject { |entry| entry.coi_tool.blank? && entry.headless_command.blank? }.map(&:key),
      supported
    assert_includes supported, "claude_code"
    assert_includes supported, "copilot", "not a coi tool, but it has a command"
  end
end
