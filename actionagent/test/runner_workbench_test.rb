# frozen_string_literal: true

require "test_helper"
# The mock provider's message types are referenced directly below; the engine's
# compatibility shim does not autoload the framework's provider namespace.
require "active_agent/providers/mock/messages/_types"

# The agent runner as a conversation workbench: runs pinned to a persisted
# conversation, files attached through Active Storage and delivered to the
# model, the conversation edited in place, and the render_ui tool.
#
# Runs use the mock provider (the only one the test environment accepts);
# the dummy host has Active Storage tables and the :test disk service.
class RunnerWorkbenchTest < ActionDispatch::IntegrationTest
  PNG = File.expand_path("../../docs/public/sales_chart.png", __dir__)
  PDF = File.expand_path("../../test/fixtures/files/sample_resume.pdf", __dir__)
  CSV_FILE = File.expand_path("../../test/fixtures/files/quarterly_sales.csv", __dir__)

  def setup
    ActionAgent::AgentMessage.delete_all
    ActionAgent::AgentGeneration.delete_all
    ActionAgent::AgentContext.delete_all
    ActionAgent::AgentRun.delete_all
    ActionAgent::Agent.delete_all
    @agent = ActionAgent::Agent.create!(
      name: "Sales Copilot", provider: "mock", model: "mock", instructions: "Answer as Acme's sales assistant."
    )
  end

  def create_context(action = "ask", agent: @agent, **attributes)
    ActionAgent::AgentContext.create!(
      { contextable: agent, agent_name: agent.telemetry_agent_class, action_name: action }.merge(attributes)
    )
  end

  def png_upload
    Rack::Test::UploadedFile.new(PNG, "image/png")
  end

  def pdf_upload
    Rack::Test::UploadedFile.new(PDF, "application/pdf")
  end

  def csv_upload
    Rack::Test::UploadedFile.new(CSV_FILE, "text/csv")
  end

  def zip_attachable
    { io: StringIO.new("PK\x03\x04not really"), filename: "archive.zip", content_type: "application/zip" }
  end

  def service_for(run)
    ActionAgent::AgentExecutionService.new(@agent, run)
  end

  # --- Attachments on runs ---------------------------------------------------

  test "the attachment manifest sorts files into what the model can take" do
    run = @agent.agent_runs.create!(input_prompt: "look", status: :pending)
    run.attachments.attach(png_upload, pdf_upload, csv_upload, zip_attachable)

    manifest = run.reload.attachment_manifest

    assert_equal %w[sales_chart.png sample_resume.pdf quarterly_sales.csv archive.zip], manifest.map { |a| a["filename"] }
    assert_equal %w[image document text file], manifest.map { |a| a["kind"] }
    manifest.each do |entry|
      assert entry["signed_id"].present?
      assert_operator entry["byte_size"], :>, 0
      assert_match %r{\A/rails/active_storage/blobs/redirect/}, entry["url"]
    end
    assert_equal File.size(PNG), manifest.first["byte_size"]
    assert_equal manifest, run.summary[:attachments]

    # Text formats browsers upload as octet-stream are still inlined.
    assert_equal "text", ActionAgent::AgentRun.attachment_kind("application/octet-stream", "notes.md")
    assert_equal "text", ActionAgent::AgentRun.attachment_kind("application/json")
    assert_equal "file", ActionAgent::AgentRun.attachment_kind("application/octet-stream", "blob.bin")
  end

  test "execute takes multipart files and pins the conversation" do
    context = create_context

    post "/activeagents/api/agents/#{@agent.id}/execute", params: {
      prompt: "What does this chart show?", action_name: "ask",
      params: { context_id: context.id.to_s }, attachments: [ png_upload ]
    }

    assert_response :accepted, response.body
    run_json = JSON.parse(response.body)["run"]
    assert_equal context.id, run_json["context_id"]
    assert_equal [ "sales_chart.png" ], run_json["attachments"].map { |a| a["filename"] }

    run = ActionAgent::AgentRun.find(run_json["id"])
    assert run.attachments.attached?, "files must be attached before the job is enqueued"
    assert_equal context.id, run.input_params["context_id"]
    assert_enqueued_with(job: ActionAgent::AgentExecutionJob, args: [ run.id ])
  end

  test "a blank prompt is accepted only with files, and a top-level context_id is honoured" do
    context = create_context

    post "/activeagents/api/agents/#{@agent.id}/execute", params: { prompt: "" }
    assert_response :unprocessable_entity
    assert_equal 0, @agent.agent_runs.count

    post "/activeagents/api/agents/#{@agent.id}/execute", params: { context_id: context.id, attachments: [ csv_upload ] }
    assert_response :accepted, response.body
    run = ActionAgent::AgentRun.find(JSON.parse(response.body).dig("run", "id"))
    assert_equal "(see attached files)", run.input_prompt
    assert_equal context.id, run.context_id
  end

  test "files are refused with 422 when the host app has no Active Storage" do
    ActionAgent::AgentRun.stub(:attachments_available?, false) do
      post "/activeagents/api/agents/#{@agent.id}/execute", params: { prompt: "look", attachments: [ png_upload ] }
    end

    assert_response :unprocessable_entity
    assert_match(/active_storage:install/, JSON.parse(response.body)["error"])
    assert_equal 0, @agent.agent_runs.count, "a refused upload must not leave a run behind"
  end

  # --- The prompt ------------------------------------------------------------

  test "prompt_messages replays the pinned history and carries the files" do
    context = create_context
    context.add_user_message("What was our best region last quarter?")
    context.add_assistant_message("EMEA, at $1.24M.")
    context.messages.create!(role: "tool", content: "{}", tool_name: "calculate", tool_call_id: "call_1")
    context.messages.create!(role: "assistant", content: "")

    run = @agent.agent_runs.create!(input_prompt: "Plot this by region", status: :pending, input_params: { context_id: context.id })
    run.attachments.attach(csv_upload, png_upload, pdf_upload)

    messages = service_for(run).prompt_messages

    assert_equal 4, messages.size
    assert_equal({ role: "user", content: "What was our best region last quarter?" }, messages[0])
    assert_equal({ role: "assistant", content: "EMEA, at $1.24M." }, messages[1])

    turn = messages[2]
    assert_equal %i[role text image], turn.keys
    assert_equal "user", turn[:role]
    assert turn[:text].start_with?("Plot this by region\n\n[Attached file: quarterly_sales.csv (text/csv, "), turn[:text]
    assert_includes turn[:text], "]\n```\nregion,revenue,deals,growth\nEMEA,1240000,38,0.12\n"
    assert turn[:text].end_with?("\n```")
    assert_equal "data:image/png;base64,#{Base64.strict_encode64(File.binread(PNG))}", turn[:image]

    assert_equal %i[role document], messages[3].keys
    assert_equal "data:application/pdf;base64,#{Base64.strict_encode64(File.binread(PDF))}", messages[3][:document]

    assert_equal "Plot this by region", run.reload.input_prompt, "inlining must not touch the run's own prompt"
  end

  test "oversize media and binaries are described rather than sent" do
    # A blob record with no bytes behind it: the cap is checked on
    # byte_size, so nothing should ever try to download it.
    huge = ActiveStorage::Blob.create_before_direct_upload!(
      filename: "huge.png", byte_size: 9.megabytes, checksum: "none", content_type: "image/png",
      metadata: { identified: true }
    )
    run = @agent.agent_runs.create!(input_prompt: "look", status: :pending)
    run.attachments.attach(huge, zip_attachable)

    messages = service_for(run).prompt_messages

    assert_equal 1, messages.size
    assert_equal %i[role content], messages.first.keys
    assert_includes messages.first[:content], "[Attached file: huge.png (image/png, 9 MB) — not sent to the model]"
    assert_includes messages.first[:content], "[Attached file: archive.zip (application/zip, "
    assert_includes messages.first[:content], "— not sent to the model]"
  end

  test "a text attachment is read only as far as it is sent" do
    body = "region,revenue\n" + ("EMEA,1240000\n" * 20_000)
    assert_operator body.bytesize, :>, ActionAgent::AgentExecutionService::ATTACHMENT_TEXT_BYTE_LIMIT
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(body), filename: "sales.csv", content_type: "text/csv"
    )
    run = @agent.agent_runs.create!(input_prompt: "summarize this", status: :pending)
    run.attachments.attach(blob)
    service = service_for(run)

    # The whole-blob read is what the cap exists to prevent: only the head of
    # the file may be fetched, however large the file is.
    prefix = blob.stub(:download, ->(*) { flunk "the whole blob must not be read into memory" }) do
      service.send(:text_prefix, blob)
    end
    assert_equal ActionAgent::AgentExecutionService::ATTACHMENT_TEXT_LIMIT, prefix.length
    assert prefix.start_with?("region,revenue\n")

    inlined = service.prompt_messages.first[:content]
    assert_includes inlined, "[Attached file: sales.csv (text/csv, "
    assert_includes inlined, "\n… (truncated)\n```"
  end

  test "a file the storage service cannot produce costs the file, not the run" do
    # A blob row whose bytes were never uploaded: reading it raises.
    missing = ActiveStorage::Blob.create_before_direct_upload!(
      filename: "notes.csv", byte_size: 24, checksum: "none", content_type: "text/csv",
      metadata: { identified: true }
    )
    run = @agent.agent_runs.create!(input_prompt: "read this", status: :pending)
    run.attachments.attach(missing)

    messages = service_for(run).prompt_messages

    assert_equal 1, messages.size
    assert_includes messages.first[:content], "[Attached file: notes.csv (text/csv, 24 Bytes) — not sent to the model]"
  end

  test "replayed history always begins on a user turn" do
    context = create_context
    context.add_user_message("q1 " * 20_000)
    context.add_assistant_message("a1 " * 7_000)
    context.add_user_message("q2")
    context.add_assistant_message("a2")
    run = @agent.agent_runs.create!(input_prompt: "and now?", status: :pending, input_params: { context_id: context.id })

    messages = service_for(run).prompt_messages

    # The oldest question does not fit the budget, so the answer that went
    # with it must go too rather than opening the conversation.
    assert_equal %w[user assistant user], messages.map { |m| m[:role] }
    assert_equal "q2", messages.first[:content]
  end

  test "a context of another agent is not continued" do
    other = ActionAgent::Agent.create!(name: "Other", provider: "mock", model: "mock")
    theirs = create_context(agent: other)
    theirs.add_user_message("their secret")
    run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending, input_params: { context_id: theirs.id })

    service = service_for(run)

    assert_equal [ { role: "user", content: "hi" } ], service.prompt_messages
    assert_nil service.send(:conversation_context)
  end

  test "the prompt span records the transcript with placeholders for media" do
    context = create_context
    context.add_user_message("Earlier question")
    run = @agent.agent_runs.create!(input_prompt: "What does this show?", status: :pending, input_params: { context_id: context.id })
    run.attachments.attach(png_upload, pdf_upload)
    root = ActiveAgent::Telemetry::Span.new("SalesCopilotAgent.prompt", trace_id: run.trace_id, span_type: :root)

    service_for(run).record_prompt_span(root)

    span = root.children.first
    assert_equal 3, span.attributes["messages.count"]
    recorded = JSON.parse(span.attributes["prompt.input.messages"])
    assert_equal [ "Earlier question", "What does this show?\n[image: sales_chart.png]", "[document: sample_resume.pdf]" ],
      recorded.map { |m| m["content"] }
    assert_not_includes span.attributes["prompt.input.messages"], "base64"
  end

  # The framework fix the workbench relies on: the mock provider has no
  # vision, but a media-only turn must still be a valid message.
  test "the mock provider accepts media-only turns" do
    type = ActiveAgent::Providers::Mock::Messages::MessageType.new

    assert_equal "[image]", type.cast({ role: "user", image: "data:image/png;base64,AAAA" }).content
    assert_equal "[document]", type.cast({ role: "user", document: "data:application/pdf;base64,AAAA" }).content
    assert_equal "look", type.cast({ role: "user", text: "look", image: "data:image/png;base64,AAAA" }).content
  end

  # --- A full run ------------------------------------------------------------

  test "a run pinned to a conversation persists one user turn with its files into that context" do
    context = create_context
    context.add_user_message("Hi!")
    context.add_assistant_message("Hello — ask me about sales.")

    run = @agent.test_execute("Plot this by region", attachments: [ csv_upload, png_upload, pdf_upload ], context_id: context.id)

    assert run.complete?, run.error_message
    assert_equal context.id, run.output_metadata["context_id"]
    assert_equal 1, ActionAgent::AgentContext.count, "the run must not open the agent's default stream"

    users = context.messages.chronological.where(role: "user").to_a
    assert_equal 2, users.size, "exactly one user message per run"
    turn = users.last
    assert_equal "Plot this by region", turn.content
    assert_equal run.trace_id, turn.provenance["trace_id"]
    assert_equal %w[quarterly_sales.csv sales_chart.png sample_resume.pdf], turn.attachments.map { |a| a["filename"] }
    assert_equal %w[text image document], turn.attachments.map { |a| a["kind"] }

    after_turn = context.messages.chronological.where("id > ?", turn.id).to_a
    assert_equal [ "assistant" ], after_turn.map(&:role)
    assert_equal run.output, after_turn.first.content
    assert_equal 1, context.generations.count

    get "/activeagents/api/runs/#{run.id}"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal context.id, body.dig("run", "context_id")
    assert_equal %w[quarterly_sales.csv sales_chart.png sample_resume.pdf], body.dig("run", "attachments").map { |a| a["filename"] }
    slice = body["messages"].reject { |m| m["role"] == "system" }
    assert_equal %w[user assistant], slice.map { |m| m["role"] }
    assert_equal "Plot this by region", slice.first["content"]
    assert_equal %w[quarterly_sales.csv sales_chart.png sample_resume.pdf], slice.first["attachments"].map { |a| a["filename"] }
  end

  # The dashboard's own runs record traces; those must belong to the agent
  # that ran, not register an "observed" twin of it.
  test "a run's trace is attributed to its agent rather than registering an observed one" do
    ActionAgent::TelemetryTrace.delete_all

    run = @agent.test_execute("Hello there")

    assert run.complete?, run.error_message
    trace = ActionAgent::TelemetryTrace.find_by!(trace_id: run.trace_id)
    assert_equal @agent.id, trace.agent_id
    assert_equal 0, ActionAgent::Agent.observed_agents.count
  end

  test "an unpinned run still lands in the agent's default stream" do
    run = @agent.test_execute("Hello there")

    assert run.complete?, run.error_message
    context = ActionAgent::AgentContext.find_by!(contextable: @agent, action_name: "ask")
    assert_equal context.id, run.output_metadata["context_id"]
    assert_equal [ "Hello there" ], context.messages.where(role: "user").map(&:content)
    assert_equal [ [] ], context.messages.where(role: "user").map(&:attachments)
  end

  test "unpinned runs keep landing in the same stream once the dashboard has started other conversations" do
    first = @agent.test_execute("Hello there")
    default_stream = ActionAgent::AgentContext.find_by!(contextable: @agent, action_name: "ask")
    # A conversation started from the runner sits on the same natural key.
    post "/activeagents/api/agents/#{@agent.id}/conversations"
    assert_response :created

    second = @agent.test_execute("And again")

    assert second.complete?, second.error_message
    assert_equal default_stream.id, first.output_metadata["context_id"]
    assert_equal default_stream.id, second.output_metadata["context_id"]
    assert_equal [ "Hello there", "And again" ], default_stream.messages.where(role: "user").map(&:content)
  end

  # --- Conversations ---------------------------------------------------------

  test "conversations are listed newest first and started per action" do
    @agent.update!(action_prompts: [ { "name" => "summarize", "prompt" => "Summarize." } ])
    older = create_context("ask", created_at: 2.hours.ago)
    older.add_user_message("hi")
    newer = create_context("ask", created_at: 1.hour.ago)
    create_context("summarize", created_at: 3.hours.ago)
    other = ActionAgent::Agent.create!(name: "Other", provider: "mock", model: "mock")
    create_context(agent: other)

    get "/activeagents/api/agents/#{@agent.id}/conversations", params: { action_name: "ask" }

    assert_response :success
    rows = JSON.parse(response.body)["conversations"]
    assert_equal [ newer.id, older.id ], rows.map { |row| row["id"] }
    assert_equal [ 0, 1 ], rows.map { |row| row["message_count"] }
    assert_equal %w[id action_name agent_name message_count last_activity_at created_at].sort, rows.first.keys.sort

    get "/activeagents/api/agents/#{@agent.id}/conversations"
    assert_equal 3, JSON.parse(response.body)["conversations"].size

    post "/activeagents/api/agents/#{@agent.id}/conversations", params: { action_name: "summarize" }

    assert_response :created
    conversation = JSON.parse(response.body)["conversation"]
    context = ActionAgent::AgentContext.find(conversation["id"])
    assert_equal "summarize", context.action_name
    assert_equal @agent.telemetry_agent_class, context.agent_name
    assert_equal @agent, context.contextable
    assert_equal "Answer as Acme's sales assistant.\n\nSummarize.", context.instructions
    assert_equal 0, conversation["message_count"]

    post "/activeagents/api/agents/#{@agent.id}/conversations"
    assert_response :created
    assert_equal "ask", JSON.parse(response.body).dig("conversation", "action_name")
  end

  test "the conversations list is bounded" do
    4.times { |i| create_context("ask", created_at: i.hours.ago) }

    get "/activeagents/api/agents/#{@agent.id}/conversations", params: { limit: 2 }

    assert_response :success
    assert_equal 2, JSON.parse(response.body)["conversations"].size
  end

  test "per-run overrides cannot supply the files or the action" do
    # These reach Agent#execute as a keyword splat, which would otherwise win
    # over the arguments the controller passes itself.
    post "/activeagents/api/agents/#{@agent.id}/execute", params: {
      prompt: "hi", params: { attachments: [ "not-a-file" ], action: "elsewhere", context_id: "0" }
    }

    assert_response :accepted, response.body
    run = ActionAgent::AgentRun.find(JSON.parse(response.body).dig("run", "id"))
    assert_not run.attachments.attached?
    assert_nil run.action_name, "the action stays the controller's to set"
    assert_equal({}, run.input_params)
  end

  test "a run whose files cannot be stored leaves no run behind" do
    assert_raises(StandardError) { @agent.execute("hi", attachments: [ "not-a-file" ]) }

    assert_equal 0, @agent.agent_runs.count
  end

  test "a conversation recorded under another action is not continued, and the run reports where it landed" do
    @agent.update!(action_prompts: [ { "name" => "summarize", "prompt" => "Summarize." } ])
    summarize = create_context("summarize", instructions: "Answer as Acme's sales assistant.\n\nSummarize.")
    summarize.add_user_message("summarize this")
    instructions = summarize.instructions

    run = @agent.test_execute("and our best region?", action: "ask", context_id: summarize.id)

    assert run.complete?, run.error_message
    landed = ActionAgent::AgentContext.find_by!(contextable: @agent, action_name: "ask")
    assert_equal landed.id, run.output_metadata["context_id"]
    assert_equal landed.id, run.context_id, "the API must report the conversation the turn is in"
    assert_equal [ "summarize this" ], summarize.messages.where(role: "user").map(&:content)
    assert_equal instructions, summarize.reload.instructions, "another action's run must not rewrite these"
  end

  # --- Editing the context ---------------------------------------------------

  test "conversation messages can be seeded, edited and deleted" do
    context = create_context
    base = "/activeagents/api/interactions/#{context.id}/messages"

    post base, params: { role: "assistant", content: "Seeded reply" }

    assert_response :created
    message = JSON.parse(response.body)["message"]
    assert_equal "assistant", message["role"]
    assert_equal "Seeded reply", message["content"]
    assert_equal [], message["attachments"]
    row = ActionAgent::AgentMessage.find(message["id"])
    assert_equal({ "source" => "dashboard", "manual" => true }, row.provenance)
    assert_equal Digest::MD5.hexdigest("Seeded reply"), row.content_checksum

    patch "#{base}/#{row.id}", params: { content: "Edited reply" }

    assert_response :success
    assert_equal "Edited reply", JSON.parse(response.body).dig("message", "content")
    assert_equal "Edited reply", row.reload.content
    assert_equal Digest::MD5.hexdigest("Edited reply"), row.content_checksum

    patch "#{base}/#{row.id}", params: { content: "" }
    assert_response :unprocessable_entity

    delete "#{base}/#{row.id}"

    assert_response :no_content
    assert_not ActionAgent::AgentMessage.exists?(row.id)

    post base, params: { role: "system", content: "nope" }
    assert_response :unprocessable_entity
    post base, params: { role: "user", content: " " }
    assert_response :unprocessable_entity
    assert_equal 0, context.messages.count

    get "/activeagents/api/interactions/#{context.id}"
    assert_response :success
  end

  test "tool rows are not editable and messages are scoped to their conversation" do
    context = create_context
    tool = context.messages.create!(role: "tool", content: "{}", tool_name: "calculate", tool_call_id: "call_1")
    base = "/activeagents/api/interactions/#{context.id}/messages"

    patch "#{base}/#{tool.id}", params: { content: "edited" }
    assert_response :unprocessable_entity
    delete "#{base}/#{tool.id}"
    assert_response :unprocessable_entity
    assert_equal "{}", tool.reload.content

    other = ActionAgent::Agent.create!(name: "Other", provider: "mock", model: "mock")
    theirs = create_context(agent: other)
    mine = context.add_user_message("mine")

    patch "/activeagents/api/interactions/#{theirs.id}/messages/#{mine.id}", params: { content: "hijacked" }
    assert_response :not_found
    delete "/activeagents/api/interactions/#{theirs.id}/messages/#{mine.id}"
    assert_response :not_found
    assert_equal "mine", mine.reload.content

    post "/activeagents/api/interactions/999999/messages", params: { role: "user", content: "x" }
    assert_response :not_found
  end

  test "the interaction API serializes each message's attachments" do
    context = create_context
    context.add_user_message("see chart", attachments: [ { "filename" => "sales_chart.png", "kind" => "image" } ])

    get "/activeagents/api/interactions/#{context.id}"

    assert_response :success
    message = JSON.parse(response.body).dig("interaction", "messages").first
    assert_equal [ { "filename" => "sales_chart.png", "kind" => "image" } ], message["attachments"]
  end

  # --- Generative UI ---------------------------------------------------------

  # The Responses API reports function calls as items, not tool-role
  # messages, so solid_agent has nothing to persist the exchange from; the
  # service's own invocation records stand in, and stand down when the
  # provider did report tool messages.
  test "tool calls are persisted from the service's records when the provider reports none" do
    context = create_context
    run = @agent.agent_runs.create!(input_prompt: "Give me a dashboard", status: :running, input_params: { context_id: context.id })
    service = service_for(run)
    blocks = [ { "type" => "stat", "label" => "Revenue", "value" => "$3.36M" } ]
    service.execute_tool("render_ui", blocks: blocks)

    tool_message = Struct.new(:role, :content)
    service.persist_tool_invocations(context, Struct.new(:messages).new([ tool_message.new("tool", "{}") ]))
    assert_equal 0, context.messages.where(role: "tool").count, "provider tool messages are persisted elsewhere"

    service.persist_tool_invocations(context, Struct.new(:messages).new([]))

    rows = context.messages.chronological.where(role: "tool").to_a
    assert_equal 1, rows.size
    assert_equal "render_ui", rows.first.tool_name
    assert_equal blocks, rows.first.tool_arguments["blocks"]
    assert_equal true, rows.first.tool_result["rendered"]
    assert_nil rows.first.tool_call_id
  end

  test "the ui tool offers render_ui and acknowledges well-formed blocks" do
    assert_includes ActionAgent::Agent::AVAILABLE_TOOLS, "ui"

    definitions = ActionAgent::AgentToolbox.definitions_for(%w[code ui])
    assert_equal %w[calculate render_ui], definitions.map { |definition| definition[:name] }
    render_ui = definitions.last
    assert_equal [ "blocks" ], render_ui.dig(:parameters, :required)
    assert_equal "array", render_ui.dig(:parameters, :properties, :blocks, :type)
    assert_includes render_ui[:description], "chart {chart: bar|line|area|pie"

    blocks = [ { "type" => "stat", "label" => "Revenue", "value" => "$3.4M" }, { type: "callout", tone: "info", body: "hi" } ]
    assert_equal({ rendered: true, blocks: 2 }, ActionAgent::AgentToolbox.call("render_ui", blocks: blocks))

    assert ActionAgent::AgentToolbox.call("render_ui", blocks: "stat")[:error]
    assert ActionAgent::AgentToolbox.call("render_ui", blocks: [ { "title" => "untyped" } ])[:error]
    assert ActionAgent::AgentToolbox.call("render_ui", blocks: [ "stat" ])[:error]
  end
end
