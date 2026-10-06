# frozen_string_literal: true

require "test_helper"
require "open3"

# Diffs and patches built in Ruby, checked by handing them to git: what
# `git apply` and `git am` make of a patch must be exactly the changed files.
class SandboxPatchTest < ActiveSupport::TestCase
  Patch = ActionAgent::SandboxPatch

  def setup
    super
    @repo = Pathname(Dir.mktmpdir("sandbox-patch")).realpath
  end

  def teardown
    FileUtils.rm_rf(@repo)
    super
  end

  test "a patch of every kind of change applies with git apply and git am, and yields exactly the new files" do
    image = "\x89PNG\r\n\x1a\n\0\0\0\rIHDR".b + Random.new(7).bytes(300)
    base = {
      "README.md" => "# Shop\n\nOne\nTwo\nThree\nFour\nFive\nSix\nSeven\nEight\nNine\nTen\n",
      "lib/old.rb" => "OLD = 1\n",
      "bin/setup" => "#!/bin/sh\necho setup\n",
      "logo.png" => image,
      "no_newline.txt" => "first\nlast",
      "naïve file.txt" => "café\n"
    }
    commit = init_repository!(base)
    changes = [
      change("README.md", base, "# Shop\n\nOne\nTwo\nThree and a half\nFour\nFive\nSix\nSeven\nEight\nNine\nTen\nEleven\n"),
      change("app/models/gadget.rb", base, "class Gadget; end\n", status: "added"),
      change("empty.txt", base, "", status: "added"),
      { path: "lib/old.rb", status: "deleted", base_mode: "100644", mode: nil, base_content: base["lib/old.rb"], content: nil },
      change("bin/setup", base, base["bin/setup"], mode: "100755"),
      change("logo.png", base, image.reverse),
      change("no_newline.txt", base, "first\nlast\nand more"),
      change("naïve file.txt", base, "café au lait\n")
    ]
    patch = Patch.format_patch(changes, subject: "Add gadgets", body: "Opened from a sandbox.", base_commit: commit)

    assert_equal Encoding::BINARY, patch.encoding
    git("apply", "--check", stdin: patch)
    git("am", "--quiet", stdin: patch)

    assert_equal "Add gadgets", git("log", "-1", "--format=%s").strip
    assert_equal "Opened from a sandbox.", git("log", "-1", "--format=%b").strip
    changes.each do |c|
      file = @repo.join(c[:path])
      if c[:status] == "deleted"
        assert_not file.exist?, "#{c[:path]} should be deleted"
      else
        assert_equal c[:content].b, file.binread.b, c[:path]
      end
    end
    assert @repo.join("bin/setup").executable?, "the mode change is applied"
    assert_equal "", git("status", "--porcelain").strip, "the commit holds every change"
  end

  test "a text diff has three lines of context and marks a missing final newline" do
    diff = Patch.file_diff(change("a.txt", { "a.txt" => "1\n2\n3\n4\n5\n6\n7\n8\n9\n" }, "1\n2\n3\n4\nfive\n6\n7\n8\n9"))

    assert_equal <<~DIFF.b, diff.sub(/^index .*\n/, "")
      diff --git a/a.txt b/a.txt
      --- a/a.txt
      +++ b/a.txt
      @@ -2,8 +2,8 @@
       2
       3
       4
      -5
      +five
       6
       7
       8
      -9
      +9
      \\ No newline at end of file
    DIFF
  end

  test "changes far apart get hunks of their own" do
    before = (1..30).map { |n| "line #{n}\n" }.join
    after = before.sub("line 2\n", "line two\n").sub("line 28\n", "line twenty-eight\n")

    diff = Patch.file_diff(change("a.txt", { "a.txt" => before }, after))

    assert_equal [ "@@ -1,5 +1,5 @@", "@@ -25,6 +25,6 @@" ], diff.lines.grep(/\A@@/).map(&:strip)
  end

  test "a file too different to search falls back to replacing every line, and still applies" do
    before = (1..(Patch::MAX_EDIT_DISTANCE + 10)).map { |n| "old #{n}\n" }.join
    after = (1..(Patch::MAX_EDIT_DISTANCE + 10)).map { |n| "new #{n}\n" }.join
    commit = init_repository!("big.txt" => before)

    patch = Patch.format_patch([ change("big.txt", { "big.txt" => before }, after) ], subject: "Rewrite", base_commit: commit)
    git("apply", stdin: patch)

    assert_equal after, @repo.join("big.txt").read
  end

  test "binary files are detected by a NUL byte, and blob ids match git's" do
    assert Patch.binary?("abc\0def")
    assert_not Patch.binary?("plain text\n")
    assert_equal "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", Patch.blob_id("")
    init_repository!("x.txt" => "hello\n")
    assert_equal git("rev-parse", "HEAD:x.txt").strip, Patch.blob_id("hello\n")
  end

  test "paths with quotes, control characters or non-ASCII bytes are quoted the way git quotes them" do
    assert_equal "a/plain name.rb", Patch.quote_path("a/plain name.rb")
    assert_equal "\"a/caf\\303\\251\"", Patch.quote_path("a/café")
    assert_equal "\"a/tab\\there\"", Patch.quote_path("a/tab\there")
    assert_equal "\"a/say \\\"hi\\\"\"", Patch.quote_path("a/say \"hi\"")
  end

  private

  def change(path, base, content, status: "modified", mode: "100644")
    { path: path, status: status, base_mode: status == "added" ? nil : "100644", mode: mode,
      base_content: status == "added" ? nil : base.fetch(path).b, content: content.b }
  end

  def init_repository!(files)
    git("init", "-q")
    files.each do |path, content|
      file = @repo.join(path)
      FileUtils.mkdir_p(file.dirname)
      file.binwrite(content)
    end
    git("add", "--all")
    git("commit", "-q", "-m", "Base")
    git("rev-parse", "HEAD").strip
  end

  def git(*args, stdin: nil)
    env = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" }
    argv = [ "git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
      "-c", "init.defaultBranch=main", "-c", "core.quotePath=true", *args ]
    output, status = Open3.capture2e(env, *argv, chdir: @repo.to_s, stdin_data: stdin.to_s, binmode: true)
    assert status.success?, "git #{args.join(' ')} failed: #{output}"
    output
  end
end
