# frozen_string_literal: true

# A stand-in for the Anthropic Messages API, for rehearsing the demo with no
# key and no network: bin/rehearse starts it and points the app at it.
#
# It is a script, not a model. It answers a handful of phrasings about the
# seeded backlog by calling the tools the request offers, says so when a
# request offers no tool for the job, and grades evaluation answers by rule.
# It exists so every screen of the demo can be walked through offline, and so
# there is something to fall back on if the venue network fails. What a real
# model says will differ: rehearse with a key before the day.
require "json"
require "rackup"
require "securerandom"

module RehearsalProvider
  TEAMS = %w[checkout billing auth search notifications api support].freeze

  module_function

  def call(env)
    request = Rack::Request.new(env)
    return [ 404, { "content-type" => "application/json" }, [ '{"error":"not found"}' ] ] unless request.post?

    body = JSON.parse(request.body.read)
    message = build_message(body)
    if body["stream"]
      [ 200, { "content-type" => "text/event-stream" }, sse(message) ]
    else
      [ 200, { "content-type" => "application/json" }, [ JSON.generate(message) ] ]
    end
  end

  def build_message(body)
    system = Array(body["system"]).map { |part| part.is_a?(Hash) ? part["text"] : part }.join("\n")
    content = system.match?(/evaluation judge|diagnose why an AI agent failed/) ? judge(body) : converse(body)
    {
      id: "msg_#{SecureRandom.hex(8)}", type: "message", role: "assistant", model: body["model"],
      content: content,
      stop_reason: content.any? { |block| block[:type] == "tool_use" } ? "tool_use" : "end_turn",
      stop_sequence: nil,
      usage: { input_tokens: JSON.generate(body).length / 4, output_tokens: JSON.generate(content).length / 4 }
    }
  end

  # --- the agent's turns ----------------------------------------------------

  def converse(body)
    offered = Array(body["tools"]).map { |tool| tool["name"] }
    turn = current_turn(body["messages"])
    plan = plan_for(turn[:text])
    step = plan[turn[:results].size]

    if step.nil?
      [ text(summarize(turn)) ]
    elsif !offered.include?(step[:tool])
      [ text(cannot(step[:tool], offered)) ]
    else
      input = step[:input].respond_to?(:call) ? step[:input].call(turn[:results]) : step[:input]
      [ { type: "tool_use", id: "toolu_#{SecureRandom.hex(8)}", name: step[:tool], input: input } ]
    end
  end

  # The newest user message that is text, and the tool results since.
  def current_turn(messages)
    index = messages.rindex { |message| message["role"] == "user" && plain_text(message).length.positive? } || 0
    results = messages[index..].flat_map do |message|
      Array(message["content"]).grep(Hash).select { |block| block["type"] == "tool_result" }
    end
    { text: plain_text(messages[index]), results: results.map { |block| parse_result(block["content"]) } }
  end

  def plain_text(message)
    content = message["content"]
    return content.to_s if content.is_a?(String)

    content.grep(Hash).select { |block| block["type"] == "text" }.map { |block| block["text"] }.join(" ").strip
  end

  def parse_result(content)
    raw = content.is_a?(Array) ? content.map { |part| part["text"] }.join : content.to_s
    JSON.parse(raw)
  rescue JSON::ParserError
    { "text" => raw }
  end

  def plan_for(message)
    said = message.downcase
    id = said[/#(\d+)/, 1]&.to_i
    team = TEAMS.find { |name| said.include?(name) }

    case said
    when /assign/
      return [ step("find_issues", {}) ] unless id

      [ step("find_users", team ? { team: team } : {}),
        step("update_issue", ->(results) { { id: id, assignee_id: results.last.dig("results", 0, "id"), reason: "Owner of the component." } }) ]
    when /duplicate/
      original = said.scan(/#(\d+)/).flatten.map(&:to_i).last
      [ step("update_issue", { id: id, duplicate_of_id: original, status: "closed", reason: "Same report." }) ]
    when /\b(close|resolve|reopen)\b/
      status = { "close" => "closed", "resolve" => "resolved", "reopen" => "open" }.fetch(Regexp.last_match(1))
      [ step("update_issue", { id: id, status: status }) ]
    when /priority|bump|escalate/
      level = %w[urgent high medium low].find { |name| said.include?(name) } || "high"
      [ step("update_issue", { id: id, priority: level }) ]
    when /\b(file|report|open) (a|an)( new)? (bug|issue)/
      title = message.sub(/\A.*?(bug|issue)\W*(about|for|that)?\W*/i, "").strip
      [ step("search_issues", { query: title.split.first(3).join(" ") }),
        step("create_issue", { title: title[0, 140], priority: "medium" }) ]
    when /comment/
      [ step("add_comment", { issue_id: id, body: message.sub(/\A.*?:\s*/, "") }) ]
    when /who owns|owner/
      [ step("find_users", team ? { team: team } : {}),
        step("find_issues", ->(results) { { assignee_id: results.last.dig("results", 0, "id"), status: "open" } }) ]
    when /how many/
      [ step("count_issues", { status: "open" }.merge(team ? { component: team } : {})) ]
    when /unassigned|nobody|no one/
      [ step("find_issues", { assignee_id: { present: false }, status: "open" }) ]
    when /urgent|on fire|burning/
      [ step("find_issues", { priority: "urgent" }) ]
    when /about (.+?)\??\z/, /search for (.+?)\??\z/, /find (.+?)\??\z/
      [ step("search_issues", { query: Regexp.last_match(1).sub(/\A(the|an|a) /, "") }) ]
    else
      id ? [ step("get_issue", { id: id }) ] : []
    end
  end

  def step(tool, input) = { tool: tool, input: input }

  def cannot(tool, offered)
    verb = tool.start_with?("find", "count", "get", "search") ? "look that up" : "change issues"
    "I can't #{verb}: I have no tool for that (I would need #{tool}). " \
      "#{offered.empty? ? "I have no tools at all." : "I can use #{offered.join(", ")}."}"
  end

  def summarize(turn)
    return "I can look things up in the backlog and, where I have the tools, change issues. " \
           "Try asking what is urgent, or whether there is already an issue about something." if turn[:results].empty?

    last = turn[:results].last
    if last["error"]
      "That did not work: #{last["error"]}"
    elsif last["results"]
      rows = last["results"]
      return "Nothing in the backlog matches." if rows.empty?

      lines = rows.first(8).map { |row| describe(row) }
      "I found #{rows.size}:\n\n#{lines.join("\n")}"
    elsif last.key?("count")
      "There are #{last["count"]}."
    elsif last["title"]
      "Done. #{describe(last)}"
    elsif last["body"]
      "Comment added to ##{last["issue_id"]}."
    else
      "Done."
    end
  end

  def describe(row)
    return "#{row["name"]} (@#{row["handle"]}) owns #{row["team"]}" if row["handle"]

    details = [ row["priority"], row["status"]&.tr("_", " "), row["component"],
                (row["assignee_id"] ? "assigned to user #{row["assignee_id"]}" : "unassigned"),
                ("duplicate of ##{row["duplicate_of_id"]}" if row["duplicate_of_id"]) ].compact
    "##{row["id"]} #{row["title"]} (#{details.join(", ")})"
  end

  # --- the evaluation judge ---------------------------------------------------

  def judge(body)
    prompt = plain_text(body["messages"].last)
    refused = prompt.match?(/I can't|I cannot|no tool for that/i)

    answer =
      if prompt.include?('"winner"')
        winner = prompt.scan(/^(\S+): pass rate ([\d.]+)%/).max_by { |_, rate| rate.to_f }&.first
        { winner: winner, rationale: "It completed the most scenarios." }
      elsif prompt.include?('"recommendation"')
        missing = prompt[/I would need (\w+)/, 1]
        if missing
          { recommendation: "The agent was asked to change an issue and has no tool that can. Enable #{missing} for it.",
            suggested_tool: { name: missing, description: "Changes the issue as the user asked" }, instruction_change: nil }
        else
          { recommendation: "The tools suffice. Tell the agent to search before it answers.",
            suggested_tool: nil, instruction_change: "Always look the issue up before answering about it." }
        end
      else
        { score: refused ? 0.1 : 0.9 }
      end
    [ text(JSON.generate(answer)) ]
  end

  def text(string) = { type: "text", text: string }

  # --- streaming --------------------------------------------------------------

  def sse(message)
    events = [ [ "message_start", { type: "message_start", message: message.merge(content: [], stop_reason: nil) } ] ]
    message[:content].each_with_index do |block, index|
      if block[:type] == "text"
        events << [ "content_block_start", { type: "content_block_start", index: index, content_block: { type: "text", text: "" } } ]
        block[:text].scan(/.{1,24}/m).each do |piece|
          events << [ "content_block_delta", { type: "content_block_delta", index: index, delta: { type: "text_delta", text: piece } } ]
        end
      else
        events << [ "content_block_start", { type: "content_block_start", index: index, content_block: block.merge(input: {}) } ]
        events << [ "content_block_delta", { type: "content_block_delta", index: index,
                                             delta: { type: "input_json_delta", partial_json: JSON.generate(block[:input]) } } ]
      end
      events << [ "content_block_stop", { type: "content_block_stop", index: index } ]
    end
    events << [ "message_delta", { type: "message_delta", delta: { stop_reason: message[:stop_reason], stop_sequence: nil },
                                   usage: { output_tokens: message[:usage][:output_tokens] } } ]
    events << [ "message_stop", { type: "message_stop" } ]
    events.map { |name, data| "event: #{name}\ndata: #{JSON.generate(data)}\n\n" }
  end
end

if $PROGRAM_NAME == __FILE__
  port = Integer(ENV.fetch("REHEARSAL_PORT", "4010"))
  Rackup::Handler.get("puma").run(RehearsalProvider.method(:call), Port: port, Host: "127.0.0.1", Silent: true)
end
