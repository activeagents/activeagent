# frozen_string_literal: true

require "test_helper"

class ToolOriginTest < ActiveSupport::TestCase
  ToolOrigin = ActiveAgent::Telemetry::ToolOrigin

  test "classifies a namespaced MCP tool" do
    result = ToolOrigin.classify("mcp__playwright__browser_navigate")

    assert_equal "mcp", result[:origin]
    assert_equal "playwright", result[:server]
    assert_equal "browser_navigate", result[:tool]
  end

  test "classifies an agent-defined tool" do
    result = ToolOrigin.classify("lookup_order")

    assert_equal "agent", result[:origin]
    assert_nil result[:server]
    assert_equal "lookup_order", result[:tool]
  end

  test "keeps underscores inside a server name" do
    result = ToolOrigin.classify("mcp__github_enterprise__create_issue")

    assert_equal "github_enterprise", result[:server]
    assert_equal "create_issue", result[:tool]
  end

  test "keeps underscores inside a tool name" do
    result = ToolOrigin.classify("mcp__fs__read_text_file")

    assert_equal "fs", result[:server]
    assert_equal "read_text_file", result[:tool]
  end

  test "treats a bare mcp-prefixed name without a tool half as agent-defined" do
    result = ToolOrigin.classify("mcp__playwright")

    assert_equal "agent", result[:origin]
    assert_nil result[:server]
  end

  test "handles symbols and blank names" do
    assert_equal "mcp", ToolOrigin.classify(:"mcp__fetch__fetch")[:origin]
    assert_equal "agent", ToolOrigin.classify(nil)[:origin]
    assert_equal "", ToolOrigin.classify(nil)[:tool]
  end

  test "mcp? and server_for mirror classify" do
    assert ToolOrigin.mcp?("mcp__slack__post_message")
    assert_not ToolOrigin.mcp?("post_message")
    assert_equal "slack", ToolOrigin.server_for("mcp__slack__post_message")
    assert_nil ToolOrigin.server_for("post_message")
  end

  test "annotate writes origin attributes onto the span" do
    span = ActiveAgent::Telemetry::Span.new("tool.mcp__playwright__browser_click", trace_id: "t1", span_type: :tool)

    ToolOrigin.annotate(span, "mcp__playwright__browser_click")

    assert_equal "mcp", span.attributes["tool.origin"]
    assert_equal "playwright", span.attributes["tool.mcp_server"]
    assert_equal "browser_click", span.attributes["tool.base_name"]
  end

  test "annotate leaves no server attribute for agent-defined tools" do
    span = ActiveAgent::Telemetry::Span.new("tool.lookup_order", trace_id: "t1", span_type: :tool)

    ToolOrigin.annotate(span, "lookup_order")

    assert_equal "agent", span.attributes["tool.origin"]
    assert_not span.attributes.key?("tool.mcp_server")
  end
end
