# frozen_string_literal: true

require "test_helper"
require "mail"

# Reading the mail a sandbox's app wrote to files (SandboxMail): the newest
# message in a recipient's file, its text and links, and the refusals.
class SandboxMailTest < ActiveSupport::TestCase
  # A backend double that serves FILES and records the paths it was asked.
  class FilesBackend
    FILES = {}
    READS = []

    def create_sandbox(_session) = {}
    def status(_handle) = {}
    def terminate(_handle) = true
    def list_sandboxes = []
    def cleanup_expired = 0

    def read_file(_session, path)
      READS << path
      FILES[path]
    end
  end

  # One without read_file.
  class NoFilesBackend
    def create_sandbox(_session) = {}
    def status(_handle) = {}
    def terminate(_handle) = true
    def list_sandboxes = []
    def cleanup_expired = 0
  end

  def setup
    @saved = ActionAgent.sandbox_backends
    ActionAgent.sandbox_backends = { "files" => FilesBackend.name, "none" => NoFilesBackend.name }
    FilesBackend::FILES.clear
    FilesBackend::READS.clear
    @sandbox = ActionAgent::SandboxSession.new(session_id: SecureRandom.uuid)
  end

  def teardown
    ActionAgent.sandbox_backends = @saved
  end

  def read(to, backend: "files", secrets: [])
    ActionAgent::SandboxMail.last_message(@sandbox, to: to, secrets: secrets, orchestrator: ActionAgent::SandboxOrchestrator.new(backend: backend))
  end

  test "the newest of several messages in an address's file is read, with its links as paths on the app" do
    html = Mail.new do
      from "shop@example.com"
      to "dev@example.com"
      subject "Reset your password"
      html_part { body '<p>Hi!</p><p><a href="http://localhost:3000/password/edit?token=s3cr3t-reset-token&amp;x=1">Reset</a></p>' }
      text_part { body "Reset it at http://localhost:3000/password/edit?token=s3cr3t-reset-token&x=1" }
    end
    older = Mail.new(from: "shop@example.com", to: "dev@example.com", subject: "Welcome", body: "Date: not a header\r\n\r\nDate: either")
    FilesBackend::FILES["tmp/activeagents/mail/dev@example.com"] = "#{older.encoded}\r\n\r\n#{html.encoded}\r\n\r\n"

    message = read("dev@example.com")

    assert_equal [ "tmp/activeagents/mail/dev@example.com" ], FilesBackend::READS
    assert_equal "Reset your password", message[:subject]
    assert_equal "dev@example.com", message[:to]
    assert_includes message[:text], "Reset it at"
    assert_equal [ "/password/edit?token=s3cr3t-reset-token&x=1" ], message[:links].map { |link| link[:path] }.uniq
  end

  test "messages that start with a Return-Path header are told apart" do
    older = Mail.new(from: "shop@example.com", to: "dev@example.com", subject: "Welcome", body: "Hello.", return_path: "bounce@example.com")
    newer = Mail.new(from: "shop@example.com", to: "dev@example.com", subject: "Confirm your account",
      body: "Confirm: http://localhost:3000/confirm?t=2", return_path: "bounce@example.com")
    assert newer.encoded.start_with?("Return-Path:"), newer.encoded.lines.first
    FilesBackend::FILES["tmp/activeagents/mail/dev@example.com"] = "#{older.encoded}\r\n\r\n#{newer.encoded}\r\n\r\n"

    assert_equal "Confirm your account", read("dev@example.com")[:subject]
  end

  test "an HTML-only message is read as text" do
    html = Mail.new(from: "shop@example.com", to: "dev@example.com", subject: "Confirm",
      content_type: "text/html; charset=UTF-8", body: "<p>Confirm <a href='http://localhost:3000/confirm?t=1'>here</a></p>")
    FilesBackend::FILES["tmp/activeagents/mail/dev@example.com"] = "#{html.encoded}\r\n\r\n"

    message = read("dev@example.com")

    assert_equal "Confirm here", message[:text]
    assert_equal [ "/confirm?t=1" ], message[:links].map { |link| link[:path] }
  end

  test "a message is scrubbed of the given secrets" do
    mail = Mail.new(from: "shop@example.com", to: "dev@example.com", subject: "Your key", body: "Your key is sk_test_mailSecret123")
    FilesBackend::FILES["tmp/activeagents/mail/dev@example.com"] = mail.encoded

    message = read("dev@example.com", secrets: [ "sk_test_mailSecret123" ])

    assert_not_includes message.to_json, "sk_test_mailSecret123"
  end

  test "no mail reads as empty, a path is not an address, and a backend without files is unsupported" do
    assert_equal({}, read("nobody@example.com"))
    assert_raises(ArgumentError) { read("../../config/master.key") }
    assert_raises(ArgumentError) { read("dev@example.com/../x") }
    assert_raises(ActionAgent::SandboxMail::Unsupported) { read("dev@example.com", backend: "none") }
    assert_equal [ "tmp/activeagents/mail/nobody@example.com" ], FilesBackend::READS
  end
end
