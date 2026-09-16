# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A release is the digest of what the model is given. These pin what goes
# into it, what stays out, and that a change to any input is a new digest.
class ReleaseTest < ActiveSupport::TestCase
  class BillingAgent < ApplicationAgent
    generate_with :mock, temperature: 0.2, api_key: "sk-not-for-the-manifest"

    def summarize
      prompt(message: "summarize")
    end
  end

  class OtherAgent < ApplicationAgent
    generate_with :mock

    def summarize
      prompt(message: "summarize")
    end
  end

  setup do
    BillingAgent.reset_release!
    OtherAgent.reset_release!
  end

  teardown { ActiveAgent::Release.revision = nil }

  test "the manifest names what the model is given, without credentials" do
    manifest = BillingAgent.release_manifest

    assert_equal "ReleaseTest::BillingAgent", manifest["agent"]
    assert manifest.key?("provider")
    assert_includes manifest["actions"], "summarize"
    assert_equal 0.2, manifest["options"]["temperature"]
    assert_not manifest["options"].key?("api_key")
    assert_no_match(/sk-not-for-the-manifest/, JSON.generate(manifest))
  end

  test "the digest is short, stable, and differs between agents" do
    assert_match(/\A\h{12}\z/, BillingAgent.release_digest)
    assert_equal BillingAgent.release_digest, BillingAgent.release_digest
    assert_not_equal BillingAgent.release_digest, OtherAgent.release_digest
  end

  test "a change to a prompt template is a new release" do
    Dir.mktmpdir do |root|
      dir = File.join(root, "release_test/billing_agent")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "instructions.md.erb"), "Be brief.")
      BillingAgent.view_paths = [ root ]
      BillingAgent.reset_release!

      before = BillingAgent.release_digest
      assert_equal [ "release_test/billing_agent/instructions.md.erb" ], BillingAgent.release_manifest["templates"].keys

      File.write(File.join(dir, "instructions.md.erb"), "Be thorough.")
      BillingAgent.reset_release!

      assert_not_equal before, BillingAgent.release_digest
    ensure
      BillingAgent.view_paths = ApplicationAgent.view_paths
      BillingAgent.reset_release!
    end
  end

  test "the revision is configured, computed, or read from the deploy environment" do
    ActiveAgent::Release.revision = "abc1234"
    assert_equal "abc1234", ActiveAgent::Release.revision

    ActiveAgent::Release.revision = -> { "def5678" }
    assert_equal "def5678", ActiveAgent::Release.revision

    ActiveAgent::Release.revision = nil
    with_env("GIT_SHA" => "0123abc") { assert_equal "0123abc", ActiveAgent::Release.revision }
  end

  test "the telemetry service version follows the release revision unless set" do
    config = ActiveAgent::Telemetry.configuration
    ActiveAgent::Release.revision = "rev-1"
    assert_equal "rev-1", config.service_version

    config.service_version = "2026.09"
    assert_equal "2026.09", config.service_version
  ensure
    config.service_version = nil
  end

  private

  def with_env(values)
    previous = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
