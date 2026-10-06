# frozen_string_literal: true

require "test_helper"
require "open3"

# A preview, a patch and a publish of a :local checkout, with every process
# the dashboard starts recorded: none of them may be handed a GitHub token,
# in its environment or its arguments. The publish itself goes to a stubbed
# GitHub from the dashboard's own process.
class DraftPullRequestLocalTest < ActiveSupport::TestCase
  OAUTH_TOKEN = "gho_#{'L' * 36}"
  REPO = "acme/shop"
  API = "https://api.github.com/repos/#{REPO}"

  def setup
    super
    ActionAgent::DraftPullRequest.delete_all
    ActionAgent::SandboxSession.delete_all
    ActionAgent::GithubConnection.delete_all
    @tmp = Pathname(Dir.mktmpdir("draft-pr-local")).realpath
    @saved = {
      enabled: ActionAgent.instance_variable_get(:@local_sandboxes_enabled),
      root: ActionAgent.instance_variable_get(:@local_sandbox_root),
      service: ActionAgent.sandbox_service
    }
    ActionAgent.local_sandboxes_enabled = true
    ActionAgent.local_sandbox_root = @tmp.join("sandboxes").to_s
    ActionAgent.sandbox_service = :local
    ActionAgent::GithubConnection.create!(
      access_token: OAUTH_TOKEN, scopes: "repo", github_user_id: 42, login: "octocat",
      repositories: [ ActionAgent::GithubClient.slice_repository({ "id" => 5, "full_name" => REPO, "default_branch" => "main" }) ]
    )
    @sandbox = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: REPO)
    @sandbox.update_columns(status: ActionAgent::SandboxSession.statuses[:ready])
    @app = @tmp.join("sandboxes", @sandbox.session_id, "app")
  end

  def teardown
    ActionAgent.instance_variable_set(:@local_sandboxes_enabled, @saved[:enabled])
    ActionAgent.instance_variable_set(:@local_sandbox_root, @saved[:root])
    ActionAgent.sandbox_service = @saved[:service]
    FileUtils.rm_rf(@tmp)
    super
  end

  test "previewing, downloading the patch and publishing start no process with a GitHub token" do
    base = checkout!("README.md" => "# Shop\n", "lib/old.rb" => "OLD = 1\n")
    @app.join("README.md").write("# Shop v2\n")
    @app.join("lib/old.rb").delete
    @app.join("app").mkpath
    @app.join("app/gadget.rb").write("class Gadget; end\n")
    stub_github!(base)
    publisher = ActionAgent::DraftPullRequestPublisher.new(@sandbox)

    spawns = record_spawns do
      preview = publisher.preview
      assert_equal %w[README.md app/gadget.rb lib/old.rb], preview[:files].map { |file| file[:path] }

      patch = publisher.patch(title: "Add gadgets")
      assert_match(/^\+# Shop v2$/, patch)

      changes = publisher.changes
      record = @sandbox.draft_pull_requests.create!(
        repository: REPO, branch: "activeagent/gadgets", title: "Add gadgets", base_commit: base,
        files: changes.publishable.map { |file| { "path" => file.path, "status" => file.status, "mode" => file.mode, "digest" => file.digest } }
      )
      publisher.publish!(record)
      assert_equal "published", record.status, record.error_message
    end

    assert spawns.any?, "the local backend reads the checkout with git"
    spawns.each do |env, argv|
      values = env.values.map(&:to_s) + argv
      assert values.none? { |value| value.include?(OAUTH_TOKEN) || value.match?(ActionAgent::SecretScrubber::GITHUB_TOKEN) },
        "#{argv.inspect} was started with a GitHub token"
    end
    assert_requested(:post, "#{API}/git/blobs", times: 2) { |request| request.headers["Authorization"] == "Bearer #{OAUTH_TOKEN}" }
  end

  private

  def checkout!(files)
    @app.mkpath
    git("init", "-q")
    files.each { |path, content| @app.join(path).tap { |file| file.dirname.mkpath }.write(content) }
    git("add", "--all")
    git("commit", "-q", "-m", "Initial")
    commit = git("rev-parse", "HEAD").strip
    @app.dirname.join("state.json").write(JSON.generate("checkout_commit" => commit))
    commit
  end

  def git(*args)
    env = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" }
    argv = [ "git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", *args ]
    output, status = Open3.capture2e(env, *argv, chdir: @app.to_s)
    assert status.success?, "git #{args.join(' ')} failed: #{output}"
    output
  end

  def stub_github!(base)
    stub_request(:get, "#{API}/git/ref/heads/main").to_return(status: 200, body: { object: { sha: base } }.to_json)
    stub_request(:get, "#{API}/git/ref/heads/activeagent/gadgets").to_return(status: 404, body: { message: "Not Found" }.to_json)
    stub_request(:get, "#{API}/git/commits/#{base}").to_return(status: 200, body: { tree: { sha: "c" * 40 } }.to_json)
    stub_request(:post, "#{API}/git/blobs").to_return(status: 201, body: { sha: "1" * 40 }.to_json)
    stub_request(:post, "#{API}/git/trees").to_return(status: 201, body: { sha: "2" * 40 }.to_json)
    stub_request(:post, "#{API}/git/commits").to_return(status: 201, body: { sha: "3" * 40 }.to_json)
    stub_request(:post, "#{API}/git/refs").to_return(status: 201, body: {}.to_json)
    stub_request(:post, "#{API}/pulls").to_return(status: 201, body: { number: 3, html_url: "https://github.com/#{REPO}/pull/3", state: "open", draft: true }.to_json)
  end

  # Every Process.spawn made inside the block, as [env, argv].
  def record_spawns
    spawns = []
    original = Process.method(:spawn)
    recorder = lambda do |*args, **options|
      env = args.first.is_a?(Hash) ? args.first : {}
      spawns << [ env, args.drop(env.empty? ? 0 : 1).map(&:to_s) ]
      original.call(*args, **options)
    end
    Process.stub(:spawn, recorder) { yield }
    spawns
  end
end
