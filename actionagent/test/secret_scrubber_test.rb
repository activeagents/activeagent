# frozen_string_literal: true

require "test_helper"

# SecretScrubber's GitHub token patterns, which mask a token the caller no
# longer knows by value.
class SecretScrubberTest < ActiveSupport::TestCase
  TOKENS = {
    "personal" => "ghp_#{'a1B2' * 9}",
    "OAuth" => "gho_#{'c3D4' * 9}",
    "App user" => "ghu_#{'e5F6' * 9}",
    "installation" => "ghs_#{'g7H8' * 9}",
    "refresh" => "ghr_#{'i9J0' * 19}",
    "fine-grained" => "github_pat_11ABCDEFG0#{'k' * 12}_#{'L' * 59}"
  }.freeze

  test "every GitHub token format is masked even when no values are given" do
    TOKENS.each do |kind, token|
      scrubbed = ActionAgent::SecretScrubber.scrub("fatal: could not read from https://x-access-token:#{token}@github.com/acme/shop", [])

      assert_not_includes scrubbed, token, "a #{kind} token"
      assert_includes scrubbed, ActionAgent::SecretScrubber::MASK
    end
  end

  test "nested data is masked too" do
    token = TOKENS["installation"]
    scrubbed = ActionAgent::SecretScrubber.scrub({ "env" => { "GH_TOKEN" => token }, "lines" => [ "Authorization: token #{token}" ] }, nil)

    assert_equal({ "env" => { "GH_TOKEN" => "[REDACTED]" }, "lines" => [ "Authorization: token [REDACTED]" ] }, scrubbed)
  end

  test "a token is masked whatever comes straight before it" do
    token = TOKENS["installation"]
    {
      "url=https%3A%2F%2Fx-access-token%3A#{token}%40github.com" => "url=https%3A%2F%2Fx-access-token%3A[REDACTED]%40github.com",
      "remote=https%3A%2F%2Fx%3D#{token}" => "remote=https%3A%2F%2Fx%3D[REDACTED]",
      "GITHUB_TOKEN_#{token}" => "GITHUB_TOKEN_[REDACTED]",
      "{\"u\":\"x-access-token\\u003a#{token}\"}" => "{\"u\":\"x-access-token\\u003a[REDACTED]\"}"
    }.each do |text, expected|
      assert_equal expected, ActionAgent::SecretScrubber.scrub(text, []), text
    end
  end

  test "words that only start like a token are left alone" do
    text = "use ghp_example in the docs, see the ghs_ prefix, and gh_pages"

    assert_equal text, ActionAgent::SecretScrubber.scrub(text, [])
  end

  test "given values are still masked beside the patterns" do
    assert_equal "token [REDACTED] and [REDACTED]",
      ActionAgent::SecretScrubber.scrub("token v1.0123456789abcdef and #{TOKENS['personal']}", [ "v1.0123456789abcdef" ])
  end

  test "text with bytes invalid in its encoding is scrubbed rather than raising" do
    text = "#{TOKENS['installation']} \xFF".dup.force_encoding("UTF-8")

    assert_equal "[REDACTED] �", ActionAgent::SecretScrubber.scrub(text, [])
  end
end
