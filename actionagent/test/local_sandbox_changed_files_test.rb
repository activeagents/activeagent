# frozen_string_literal: true

require "test_helper"
require "open3"

# The :local backend's read-only verbs, changed_files and read_file, against
# a real git checkout laid out the way a boot leaves one: the workspace's
# app/ directory, and state.json naming the commit that was checked out.
class LocalSandboxChangedFilesTest < ActiveSupport::TestCase
  Backend = ActionAgent::LocalSandboxBackend
  SandboxDouble = Struct.new(:session_id, :checkout_spec, keyword_init: true)
  CHECKOUT_TOKEN = "ghs_#{'C' * 36}"

  def setup
    super
    @tmp = Pathname(Dir.mktmpdir("local-changed-files")).realpath
    @saved = {
      enabled: ActionAgent.instance_variable_get(:@local_sandboxes_enabled),
      root: ActionAgent.instance_variable_get(:@local_sandbox_root)
    }
    ActionAgent.local_sandboxes_enabled = true
    ActionAgent.local_sandbox_root = @tmp.join("sandboxes").to_s
    @sandbox = SandboxDouble.new(
      session_id: SecureRandom.uuid,
      checkout_spec: { repository: "acme/shop", token: CHECKOUT_TOKEN }
    )
    @workspace = @tmp.join("sandboxes", @sandbox.session_id)
    @app = @workspace.join("app")
    @outside = @tmp.join("outside")
    FileUtils.mkdir_p(@outside)
    @outside.join("id_rsa").write("not for publishing\n")
    @backend = Backend.new
  end

  def teardown
    ActionAgent.instance_variable_set(:@local_sandboxes_enabled, @saved[:enabled])
    ActionAgent.instance_variable_set(:@local_sandbox_root, @saved[:root])
    FileUtils.rm_rf(@tmp)
    super
  end

  test "lists every change since the checkout commit with its mode, and leaves ignored files out" do
    base = checkout!(
      "README.md" => "# Shop\n",
      "bin/setup" => "#!/bin/sh\n",
      ".gitignore" => "log/\n",
      "lib/old.rb" => "OLD = 1\n",
      "docs/guide.md" => "Read me\n"
    )
    write("README.md", "# Shop\n\nNow with widgets.\n")
    write("app/models/gadget.rb", "class Gadget; end\n")
    write("app/models/intent.rb", "class Intent; end\n")
    git("add", "--intent-to-add", "app/models/intent.rb")
    @app.join("lib/old.rb").delete
    @app.join("bin/setup").chmod(0o755)
    write("log/development.log", "ignored\n")
    File.symlink(@outside.join("id_rsa").to_s, @app.join("key.txt").to_s)
    # A directory swapped for a symlink: what was under it is gone, as git sees it.
    FileUtils.rm_rf(@app.join("docs"))
    File.symlink(@outside.to_s, @app.join("docs").to_s)
    nested = @app.join("vendor/nested")
    FileUtils.mkdir_p(nested)
    git("init", "-q", chdir: nested)
    nested.join("lib.rb").write("x\n")

    changes = @backend.changed_files(@sandbox)

    assert_equal base, changes[:base_commit]
    assert_equal [
      { path: "README.md", status: "modified", mode: "100644", base_mode: "100644", size: 26 },
      { path: "app/models/gadget.rb", status: "added", mode: "100644", base_mode: nil, size: 18 },
      { path: "app/models/intent.rb", status: "added", mode: "100644", base_mode: nil, size: 18 },
      { path: "bin/setup", status: "modified", mode: "100755", base_mode: "100644", size: 10 },
      { path: "docs", status: "added", mode: "120000", base_mode: nil, size: @outside.to_s.bytesize },
      { path: "docs/guide.md", status: "deleted", mode: nil, base_mode: "100644", size: nil },
      { path: "key.txt", status: "added", mode: "120000", base_mode: nil, size: @outside.join("id_rsa").to_s.bytesize },
      { path: "lib/old.rb", status: "deleted", mode: nil, base_mode: "100644", size: nil },
      { path: "vendor/nested", status: "added", mode: "160000", base_mode: nil, size: nil }
    ], changes[:files]
  end

  test "an unchanged checkout lists nothing" do
    base = checkout!("README.md" => "# Shop\n")

    assert_equal({ base_commit: base, files: [] }, @backend.changed_files(@sandbox))
  end

  test "reads the working tree without following a symlink, and the checked-out commit with base" do
    checkout!("README.md" => "# Shop\n", "docs/guide.md" => "Read me\n", "lib/old.rb" => "OLD = 1\n")
    write("README.md", "# Shop v2\n")
    write("app/new.rb", "NEW = 1\n")
    @app.join("lib/old.rb").delete
    File.symlink(@outside.join("id_rsa").to_s, @app.join("key.txt").to_s)
    FileUtils.rm_rf(@app.join("docs"))
    File.symlink(@outside.to_s, @app.join("docs").to_s)

    assert_equal "# Shop v2\n", read("README.md")
    assert_equal Encoding::BINARY, read("README.md").encoding
    assert_equal "# Shop\n", read("README.md", base: true)
    assert_equal @outside.join("id_rsa").to_s, read("key.txt"), "a symlink reads as its target path"
    assert_nil read("docs/guide.md"), "nothing is read through a symlinked directory"
    assert_equal "Read me\n", read("docs/guide.md", base: true)
    assert_nil read("lib/old.rb")
    assert_equal "OLD = 1\n", read("lib/old.rb", base: true)
    assert_equal "NEW = 1\n", read("app/new.rb")
    assert_nil read("app/new.rb", base: true)
    assert_nil read(":(glob)*", base: true), "a path is a literal name, never a pathspec"
  end

  test "refuses what is not a regular file, and a file over the size limit" do
    checkout!("README.md" => "# Shop\n")
    nested = @app.join("vendor/nested")
    FileUtils.mkdir_p(nested)
    File.mkfifo(@app.join("pipe").to_s)
    write("big.bin", "x" * (Backend::MAX_READ_BYTES + 1))

    assert_raises(Backend::Error) { read("vendor/nested") }
    assert_raises(Backend::Error) { read("pipe") }
    error = assert_raises(Backend::Error) { read("big.bin") }
    assert_match(/larger than/, error.message)
    assert_not_includes @backend.changed_files(@sandbox)[:files].map { |file| file[:path] }, "pipe", "git does not track a pipe"
  end

  test "refuses paths outside the checkout and inside its .git directory" do
    checkout!("README.md" => "# Shop\n")

    [ "../outside/id_rsa", "/etc/passwd", ".git/config", ".GIT/config", "a//b", "./README.md" ].each do |path|
      assert_raises(Backend::Error, path) { read(path) }
    end
  end

  test "reads nothing while the checkout's git config defines a filter driver, and never runs it" do
    checkout!("README.md" => "# Shop\n")
    marker = @tmp.join("filter-ran")
    git("config", "filter.probe.clean", "touch #{marker}")
    write(".gitattributes", "* filter=probe\n")
    write("README.md", "# Shop v2\n")

    error = assert_raises(Backend::Error) { @backend.changed_files(@sandbox) }
    assert_match(/filter drivers/, error.message)
    assert_equal "# Shop\n", read("README.md", base: true), "reading the commit runs no filter"
    assert_not marker.exist?, "the filter's command must not run"
  end

  test "reads the checked-out commit as it is, whatever replace refs the checkout added" do
    checkout!("README.md" => "# Shop\n")
    original = git("rev-parse", "HEAD:README.md").strip
    forged = git_with_input("forged\n", "hash-object", "-w", "--stdin").strip
    git("replace", original, forged)

    assert_equal "# Shop\n", read("README.md", base: true)
  end

  test "a checkout that recorded no commit, or is gone, is refused" do
    checkout!("README.md" => "# Shop\n")
    @workspace.join("state.json").write("{}")

    assert_raises(Backend::Error) { @backend.changed_files(@sandbox) }

    FileUtils.rm_rf(@app)
    assert_raises(Backend::Error) { @backend.changed_files(@sandbox) }
    assert_raises(Backend::Error) { read("README.md") }
  end

  test "no process it starts carries a GitHub token, and each is git with the read-only environment" do
    checkout!("README.md" => "# Shop\n", "lib/old.rb" => "OLD = 1\n")
    write("README.md", "# Shop v2\n")
    spawns = record_spawns do
      @backend.changed_files(@sandbox)
      read("README.md")
      read("README.md", base: true)
    end

    assert spawns.any?
    spawns.each do |env, argv|
      assert_equal "git", argv.first
      values = env.values + argv
      assert values.none? { |value| value.to_s.include?(CHECKOUT_TOKEN) || value.to_s.match?(ActionAgent::SecretScrubber::GITHUB_TOKEN) },
        "#{argv.inspect} was started with a GitHub token"
      assert_equal "0", env["GIT_OPTIONAL_LOCKS"]
      assert_equal "1", env["GIT_NO_REPLACE_OBJECTS"]
    end
  end

  test "the orchestrator dispatches both verbs to the local backend" do
    checkout!("README.md" => "# Shop\n")
    write("README.md", "# Shop v2\n")
    orchestrator = ActionAgent::SandboxOrchestrator.new(backend: "local")

    assert orchestrator.supports?(:changed_files)
    assert orchestrator.supports?(:read_file)
    assert_equal [ "README.md" ], orchestrator.changed_files(@sandbox)[:files].map { |file| file[:path] }
    assert_equal "# Shop\n", orchestrator.read_file(@sandbox, "README.md", base: true)
    assert_equal "# Shop v2\n", orchestrator.read_file(@sandbox, "README.md")
  end

  private

  # A checkout of a one-commit repository holding +files+, recorded in
  # state.json as a boot records it. Returns the commit.
  def checkout!(files)
    FileUtils.mkdir_p(@app)
    git("init", "-q")
    files.each { |path, content| write(path, content) }
    git("add", "--all")
    git("commit", "-q", "-m", "Initial")
    commit = git("rev-parse", "HEAD").strip
    @workspace.join("state.json").write(JSON.generate("checkout_commit" => commit))
    commit
  end

  def write(path, content)
    file = @app.join(path)
    FileUtils.mkdir_p(file.dirname)
    file.write(content)
  end

  def read(path, base: false)
    @backend.read_file(@sandbox, path, base: base)
  end

  def git(*args, chdir: @app)
    git_with_input(nil, *args, chdir: chdir)
  end

  def git_with_input(input, *args, chdir: @app)
    env = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" }
    argv = [ "git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
      "-c", "init.defaultBranch=main", *args ]
    output, status = Open3.capture2e(env, *argv, chdir: chdir.to_s, stdin_data: input.to_s)
    assert status.success?, "git #{args.join(' ')} failed: #{output}"
    output
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
