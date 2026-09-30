# frozen_string_literal: true

require "test_helper"
require "rake"

# The runtime manifest a booted checkout hands its sandbox backend (#489):
# SandboxManifest.generate and .parse, and the action_agent:sandbox tasks a
# host app gets from the engine — `manifest`, which a checkout's
# .activeagents/sandbox.yml runs to say where its MCP facade answers, and
# `reap`, which an operator schedules.
class SandboxManifestTest < ActionDispatch::IntegrationTest
  PATH_ENV = ActionAgent::SandboxManifest::PATH_ENV
  KEY_NAME = ActionAgent::SandboxManifest::KEY_NAME

  def setup
    ActionAgent::ApiKey.delete_all
    ActionAgent::SandboxSession.delete_all
    @original_manifest_path = ENV[PATH_ENV]
    ENV.delete(PATH_ENV)
  end

  def teardown
    ENV[PATH_ENV] = @original_manifest_path
  end

  test "generate names the engine's MCP path under the app's mount and a key for it" do
    manifest = ActionAgent::SandboxManifest.generate

    assert_equal %w[mcp_path mcp_token], manifest.keys.sort
    assert_equal "/activeagents/mcp", manifest["mcp_path"]
    assert_equal ActionAgent::ApiKey.find_by!(name: KEY_NAME).token, manifest["mcp_token"]
  end

  test "generate refuses an app that does not mount the engine, before minting a key" do
    error = assert_raises(ActionAgent::SandboxManifest::Error) do
      ActionAgent::SandboxManifest.generate(routes: unmounted_routes)
    end

    assert_equal "ActionAgent::Engine is not mounted in this app's routes", error.message
    assert_not ActionAgent::ApiKey.exists?(name: KEY_NAME)
  end

  test "parse reads back what generate produced" do
    manifest = ActionAgent::SandboxManifest.generate

    assert_equal manifest, ActionAgent::SandboxManifest.parse(JSON.generate(manifest))
  end

  test "parse accepts a manifest without a token and ignores unknown keys" do
    parsed = ActionAgent::SandboxManifest.parse({ mcp_path: "/tools/mcp", mcp_token: nil, extra: 1 }.to_json)

    assert_equal({ "mcp_path" => "/tools/mcp", "mcp_token" => nil }, parsed)
  end

  test "parse refuses what a backend could not dial" do
    {
      "" => /not JSON/,
      "{not json" => /not JSON/,
      "[]" => /not a JSON object/,
      "{}" => /names no mcp_path/,
      { mcp_path: "activeagents/mcp" }.to_json => /names no mcp_path/,
      { mcp_path: 42 }.to_json => /names no mcp_path/,
      { mcp_path: "/activeagents/mcp", mcp_token: 42 }.to_json => /mcp_token is not a string/
    }.each do |json, message|
      error = assert_raises(ActionAgent::SandboxManifest::Error, json) { ActionAgent::SandboxManifest.parse(json) }
      assert_match message, error.message, json
    end
  end

  test "the manifest task writes the manifest to $ACTION_AGENT_SANDBOX_MANIFEST" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "runtime.json")
      ENV[PATH_ENV] = path

      out, = capture_io { run_task("action_agent:sandbox:manifest") }

      assert_empty out, "a manifest written to a file is not also printed"
      manifest = ActionAgent::SandboxManifest.parse(File.read(path))
      assert_equal "/activeagents/mcp", manifest["mcp_path"]
      assert_equal ActionAgent::ApiKey.find_by!(name: KEY_NAME).token, manifest["mcp_token"]
    end
  end

  test "the manifest task prints the manifest when no path is set" do
    out, = capture_io { run_task("action_agent:sandbox:manifest") }

    manifest = ActionAgent::SandboxManifest.parse(out)
    assert_equal "/activeagents/mcp", manifest["mcp_path"]
    assert_equal ActionAgent::ApiKey.find_by!(name: KEY_NAME).token, manifest["mcp_token"]
  end

  # A sandbox reboots its checkout on every provision; a key per boot would
  # pile up in Settings -> API Keys.
  test "the manifest task reuses its key across runs" do
    first = ActionAgent::SandboxManifest.parse(capture_io { run_task("action_agent:sandbox:manifest") }.first)
    second = ActionAgent::SandboxManifest.parse(capture_io { run_task("action_agent:sandbox:manifest") }.first)

    assert_equal first, second
    assert_equal 1, ActionAgent::ApiKey.where(name: KEY_NAME).count
  end

  test "the manifest's token opens the MCP facade at the manifest's path" do
    manifest = ActionAgent::SandboxManifest.parse(capture_io { run_task("action_agent:sandbox:manifest") }.first)

    # What LocalSandboxBackend polls for before it reports the sandbox ready.
    get manifest["mcp_path"], headers: { "Accept" => "application/json" }
    assert_response :method_not_allowed

    body = rpc(manifest["mcp_path"], "initialize", token: manifest["mcp_token"])
    assert_response :success
    assert_nil body["error"], body.inspect
    assert_equal "2.0", body["jsonrpc"]
    assert body.dig("result", "protocolVersion"), body.inspect

    body = rpc(manifest["mcp_path"], "tools/list", token: manifest["mcp_token"])
    assert_response :success
    assert_kind_of Array, body.dig("result", "tools"), body.inspect

    rpc(manifest["mcp_path"], "initialize", token: "aa_not_the_manifest_token")
    assert_response :unauthorized
  end

  test "the manifest task aborts with the reason when the engine is not mounted" do
    generate = ActionAgent::SandboxManifest.method(:generate)
    routes = unmounted_routes

    ActionAgent::SandboxManifest.stub(:generate, ->(**) { generate.call(routes: routes) }) do
      Dir.mktmpdir do |dir|
        ENV[PATH_ENV] = File.join(dir, "runtime.json")
        exit_error = nil

        _out, err = capture_io do
          exit_error = assert_raises(SystemExit) { run_task("action_agent:sandbox:manifest") }
        end

        assert_not exit_error.success?
        assert_includes err, "action_agent:sandbox:manifest: ActionAgent::Engine is not mounted in this app's routes"
        assert_not File.exist?(ENV[PATH_ENV]), "a failed run leaves no manifest for the backend to read"
      end
    end
  end

  # The repository's own .activeagents/sandbox.yml boots test/dummy on the
  # rails8 gemfile, through a BUNDLE_GEMFILE that resolves only from
  # test/dummy: a moved gemfile or app would only surface when someone
  # started a sandbox of this repo.
  test "this repository's sandbox.yml runs every command in test/dummy on the rails8 bundle" do
    root = File.expand_path("../..", __dir__)
    dummy = File.join(root, "test", "dummy")
    config = YAML.safe_load_file(File.join(root, ".activeagents", "sandbox.yml"))
    commands = [ *config["setup"], config["manifest"], config["start"] ]

    assert commands.all? { |command| command.start_with?("cd test/dummy && ") }, commands.inspect
    assert File.executable?(File.join(dummy, "bin", "rails"))
    assert_equal File.join(root, "gemfiles", "rails8.gemfile"), File.expand_path(config.dig("env", "BUNDLE_GEMFILE"), dummy)
    assert File.file?(File.join(root, "gemfiles", "rails8.gemfile"))
    assert_includes config["manifest"], "bin/rails action_agent:sandbox:manifest"
    assert_match(/bin\/rails server -b 127\.0\.0\.1 -p "\$PORT"\z/, config["start"])
  end

  test "the reap task prints how many sessions it expired" do
    ActionAgent::SandboxCleanupJob.stub(:cleanup_expired!, 3) do
      out, = capture_io { run_task("action_agent:sandbox:reap") }

      assert_equal "Expired 3 sandbox session(s)\n", out
    end
  end

  test "the reap task expires live sessions past their expiry and leaves the rest" do
    overdue = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp")
    overdue.update_columns(status: ActionAgent::SandboxSession.statuses[:ready], expires_at: 1.minute.ago)
    current = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp")
    current.update_columns(status: ActionAgent::SandboxSession.statuses[:ready])

    out, = capture_io { run_task("action_agent:sandbox:reap") }

    assert_equal "Expired 1 sandbox session(s)\n", out
    assert overdue.reload.expired?
    assert current.reload.ready?
  end

  private

  # Invokes +name+ in a fresh Rake application holding the tasks the engine
  # gives a host app (its lib/tasks), as `bin/rails <name>` would. The
  # environment is already loaded here, so :environment does nothing.
  def run_task(name)
    original = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    ActionAgent::Engine.instance.load_tasks
    Rake::Task[name].invoke
  ensure
    Rake.application = original
  end

  # Routes that serve something but do not mount the engine. The engine
  # itself is never mounted into a throwaway set: mounting extends the
  # engine's own routes with the new set's script name, for the rest of the
  # process.
  def unmounted_routes
    ActionDispatch::Routing::RouteSet.new.tap do |routes|
      routes.draw { get "/up", to: ->(_env) { [ 200, {}, [ "ok" ] ] } }
    end
  end

  def rpc(path, method, token:)
    post path,
      params: { jsonrpc: "2.0", id: 1, method: method, params: {} }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
    JSON.parse(response.body)
  end
end
