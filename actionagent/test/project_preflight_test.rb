# frozen_string_literal: true

require "test_helper"

# Whether a repository can become a project, decided from files GitHub's
# contents API serves (a fake client here), before any sandbox exists.
class ProjectPreflightTest < ActiveSupport::TestCase
  # Serves a fixed set of files at the commit each ref names, and records
  # what was asked. +commits+ maps a ref to its commit; any other ref names
  # "sha-<ref>".
  class FakeClient
    attr_reader :requests, :commit_requests

    def initialize(files, commits = {})
      @files = files
      @commits = commits
      @requests = []
      @commit_requests = []
    end

    def commit_sha(repository, ref)
      @commit_requests << [ repository, ref ]
      @commits.fetch(ref) { "sha-#{ref}" }
    end

    def file(repository, path, ref:)
      @requests << [ repository, path, ref ]
      @files[path]
    end
  end

  test "a Rails app without the engine is supported with a bootstrap" do
    report = preflight("Gemfile.lock" => lock, "config/application.rb" => "# app\n")

    assert_equal [ "bootstrap", "Supported: installs the engine in the sandbox", [] ], report.values_at("status", "summary", "reasons")
    assert_equal [ false, "3.3.6", "Gemfile.lock", "8.0.1" ], report.values_at("engine", "ruby", "ruby_source", "railties")
  end

  test "a Rails app that bundles the engine is supported as it is" do
    report = preflight("Gemfile.lock" => lock(gems: [ "actionagent (1.9.0)", "activeagent (1.9.0)" ]), "config/application.rb" => "# app\n")

    assert_equal [ "supported", "Supported", true ], report.values_at("status", "summary", "engine")
    assert_equal [ "1.9.0", "1.9.0" ], report.values_at("activeagent", "actionagent")
  end

  test "each refusal names the requirement" do
    app = { "config/application.rb" => "# app\n" }
    cases = {
      "acme/shop has no Gemfile.lock at its root: a sandbox needs a bundled Rails app" => app,
      "acme/shop needs Ruby 3.1.4 (Gemfile.lock); the engine needs Ruby 3.2 or later" =>
        app.merge("Gemfile.lock" => lock(ruby: "3.1.4p223")),
      "acme/shop locks railties 7.1.3; the engine needs Rails 7.2 or later" => app.merge("Gemfile.lock" => lock(railties: "7.1.3")),
      "acme/shop has no config/application.rb at its root: a sandbox needs the Rails app at the repository root" =>
        { "Gemfile.lock" => lock },
      "acme/shop's Gemfile.lock locks no railties: a sandbox needs a Rails app" =>
        app.merge("Gemfile.lock" => lock.sub(/^    rails.*\n/, "").gsub(/^    railties.*\n/, ""))
    }

    cases.each do |reason, files|
      report = preflight(files)
      assert_equal [ "unsupported", reason ], report.values_at("status", "summary"), files.keys.inspect
      assert_includes report["reasons"], reason
    end
  end

  test ".ruby-version decides the Ruby when the lock pins none" do
    files = { "Gemfile.lock" => lock(ruby: nil), "config/application.rb" => "# app\n", ".ruby-version" => "ruby-3.1.2\n" }

    report = preflight(files)

    assert_equal [ "unsupported", "3.1.2", ".ruby-version" ], report.values_at("status", "ruby", "ruby_source")
  end

  test "services the sandbox does not run, and databases it cannot give a checkout, are warnings" do
    files = {
      "Gemfile.lock" => lock(gems: [ "redis (5.0.0)" ]), "config/application.rb" => "# app\n",
      "Gemfile" => "gem \"rails\"\n  gem 'searchkick'\n",
      "config/database.yml" => "production:\n  adapter: sqlserver\ndevelopment:\n  adapter: <%= ENV['ADAPTER'] %>\n"
    }

    report = preflight(files)

    assert_equal "bootstrap", report["status"], "warnings never refuse"
    assert_equal [ "Elasticsearch or OpenSearch (for Searchkick)", "Redis" ], report["services"]
    assert_equal [ "sqlserver" ], report["database_adapters"]
    assert_equal 3, report["warnings"].size
    assert_match(/sqlserver, which a local sandbox cannot give databases of its own/, report["warnings"].last)
  end

  test "every file is read once, at the commit the ref names" do
    client = FakeClient.new("Gemfile.lock" => lock, "config/application.rb" => "# app\n")

    report = ActionAgent::ProjectPreflight.call(client, repository: "acme/shop", ref: "release")

    assert_equal [ "release", "sha-release" ], report.values_at("ref", "commit")
    paths = client.requests.map { |_repository, path, _ref| path }
    assert_equal paths.uniq, paths
    assert client.requests.all? { |repository, _path, ref| repository == "acme/shop" && ref == "sha-release" }
  end

  test "a ref that names no commit is unsupported, and no file is read" do
    client = FakeClient.new({ "Gemfile.lock" => lock }, { "gone" => nil })

    report = ActionAgent::ProjectPreflight.call(client, repository: "acme/shop", ref: "gone")

    assert_equal [ "unsupported", "acme/shop has no commit at gone", nil ], report.values_at("status", "summary", "commit")
    assert_empty client.requests
  end

  test "a report is kept for its commit, and a new commit is read again" do
    files = { "Gemfile.lock" => lock, "config/application.rb" => "# app\n" }
    commits = { "main" => "a" * 40 }
    client = FakeClient.new(files, commits)

    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      first = ActionAgent::ProjectPreflight.call(client, repository: "acme/shop", ref: "main")
      reads = client.requests.size
      again = ActionAgent::ProjectPreflight.call(client, repository: "acme/shop", ref: "main")

      assert_equal first, again
      assert_equal reads, client.requests.size, "the same commit is not read again"
      assert_equal 2, client.commit_requests.size

      commits["main"] = "b" * 40
      files["Gemfile.lock"] = lock(railties: "7.1.3")
      moved = ActionAgent::ProjectPreflight.call(client, repository: "acme/shop", ref: "main")

      assert_equal [ "unsupported", "b" * 40 ], moved.values_at("status", "commit")
      assert_operator client.requests.size, :>, reads
    end
  end

  private

  def preflight(files)
    ActionAgent::ProjectPreflight.call(FakeClient.new(files), repository: "acme/shop", ref: "main")
  end

  def lock(ruby: "3.3.6p0", railties: "8.0.1", gems: [])
    specs = [ "rails (#{railties})", "railties (#{railties})", *gems ].sort.map { |spec| "    #{spec}\n" }.join
    text = +"GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n  rails\n"
    text << "\nRUBY VERSION\n   ruby #{ruby}\n" if ruby
    text << "\nBUNDLED WITH\n   2.6.2\n"
  end
end
