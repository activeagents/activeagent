# frozen_string_literal: true

require "openssl"
require "base64"

# A GitHub App configured with a key generated for the test run, and WebMock
# stubs for the GitHub endpoints the App flows call.
module GithubAppTestHelper
  APP_ID = "424242"
  SLUG = "acme-dashboard"
  CLIENT_ID = "Iv1.testclientid"
  CLIENT_SECRET = "app-client-secret-value"
  INSTALLATION_ID = 77
  GITHUB_USER_ID = 9001
  # The App user token the callback's code exchange returns. Long enough to
  # look like a real one, so a test can search logs and columns for it.
  USER_TOKEN = "ghu_#{'U' * 36}"
  API = "https://api.github.com"

  def self.private_key
    @private_key ||= OpenSSL::PKey::RSA.new(2048)
  end

  def configure_github_app!
    ActionAgent.github_app_id = APP_ID
    ActionAgent.github_app_private_key = GithubAppTestHelper.private_key.to_pem
    ActionAgent.github_app_slug = SLUG
    ActionAgent.github_app_client_id = CLIENT_ID
    ActionAgent.github_app_client_secret = CLIENT_SECRET
  end

  def reset_github_app!
    ActionAgent.github_app_id = nil
    ActionAgent.github_app_private_key = nil
    ActionAgent.github_app_slug = nil
    ActionAgent.github_app_client_id = nil
    ActionAgent.github_app_client_secret = nil
  end

  # The JWT's header and payload, after checking its RS256 signature against
  # the test key. Fails the test when the signature does not verify.
  def verified_jwt(token)
    assert jwt_signed?(token), "the JWT's signature must verify with the App's key"

    header, payload, = token.split(".")
    [ JSON.parse(Base64.urlsafe_decode64(header)), JSON.parse(Base64.urlsafe_decode64(payload)) ]
  end

  def jwt_signed?(token)
    header, payload, signature = token.to_s.split(".")
    return false unless header && payload && signature

    GithubAppTestHelper.private_key.public_key.verify(
      OpenSSL::Digest.new("SHA256"), Base64.urlsafe_decode64(signature), "#{header}.#{payload}"
    )
  rescue ArgumentError, OpenSSL::PKey::PKeyError
    false
  end

  def mint_url(installation_id = INSTALLATION_ID)
    "#{API}/app/installations/#{installation_id}/access_tokens"
  end

  def bearer(request)
    request.headers["Authorization"].to_s.delete_prefix("Bearer ")
  end

  # Stubs the mint for +installation_id+, answering with +token+ (a String),
  # or with +status+ and +message+ for a refusal. Returns the stub.
  def stub_mint(token: "ghs_#{'M' * 36}", installation_id: INSTALLATION_ID, status: 201, message: nil)
    body = status.between?(200, 299) ? { token: token, expires_at: 1.hour.from_now.iso8601 } : { message: message }
    stub_request(:post, mint_url(installation_id))
      .with { |request| jwt_signed?(bearer(request)) }
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_installation_repositories(repositories, token: "ghs_#{'M' * 36}")
    stub_request(:get, %r{\A#{API}/installation/repositories})
      .with(headers: { "Authorization" => "Bearer #{token}" })
      .to_return(status: 200, body: { total_count: repositories.size, repositories: repositories }.to_json)
  end

  # Stubs the callback's App user authorization: the code exchange, the user,
  # and the installations that user can reach.
  def stub_app_user(code: "app-code", user_id: GITHUB_USER_ID, installations: [])
    stub_request(:post, "https://github.com/login/oauth/access_token")
      .with(body: hash_including("code" => code, "client_id" => CLIENT_ID, "client_secret" => CLIENT_SECRET))
      .to_return(status: 200, body: { access_token: USER_TOKEN, refresh_token: "ghr_#{'R' * 36}", token_type: "bearer" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    stub_request(:get, "#{API}/user")
      .with(headers: { "Authorization" => "Bearer #{USER_TOKEN}" })
      .to_return(status: 200, body: { id: user_id, login: "octocat" }.to_json)
    stub_request(:get, %r{\A#{API}/user/installations})
      .with(headers: { "Authorization" => "Bearer #{USER_TOKEN}" })
      .to_return(status: 200, body: { total_count: installations.size, installations: installations }.to_json)
  end

  def stub_membership(organization, state: "active", role: "admin", status: 200)
    body = status == 200 ? { state: state, role: role, organization: { login: organization } } : { message: "Not Found" }
    stub_request(:get, "#{API}/user/memberships/orgs/#{organization}")
      .with(headers: { "Authorization" => "Bearer #{USER_TOKEN}" })
      .to_return(status: status, body: body.to_json)
  end

  # An installation as GET /user/installations describes it.
  def github_installation(id: INSTALLATION_ID, account_type: "User", account_id: GITHUB_USER_ID, login: "octocat", suspended_at: nil)
    {
      id: id,
      account: { id: account_id, login: login, type: account_type },
      repository_selection: "selected",
      permissions: { contents: "write", metadata: "read", pull_requests: "write" },
      suspended_at: suspended_at
    }
  end

  def repo_payload(id, full_name, default_branch: "main", private: true)
    { id: id, full_name: full_name, private: private, default_branch: default_branch, html_url: "https://github.com/#{full_name}" }
  end

  def link_installation!(installation_id: INSTALLATION_ID, repositories: [], **attributes)
    ActionAgent::GithubInstallation.create!(
      installation_id: installation_id, github_account_id: GITHUB_USER_ID, github_account_login: "acme",
      github_account_type: "Organization", repository_selection: "selected", repositories: repositories, **attributes
    )
  end

  def repo_row(id, full_name, default_branch: "main")
    ActionAgent::GithubClient.slice_repository(repo_payload(id, full_name, default_branch: default_branch).deep_stringify_keys)
  end
end
