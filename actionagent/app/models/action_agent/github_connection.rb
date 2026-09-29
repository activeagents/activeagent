# frozen_string_literal: true

module ActionAgent
  # An owner's GitHub OAuth grant (Settings -> Integrations) and the
  # repositories they made available to the workspace.
  #
  # The access token is encrypted at rest like a provider key and never
  # rendered back to the client. +repositories+ holds only what GitHub
  # itself listed for this token when the owner chose them (see
  # Api::GithubConnectionsController#update), so a checkout sandbox can
  # trust a name found here without asking GitHub again.
  class GithubConnection < ApplicationRecord
    include Ownable
    owned_by :account, :user

    encrypts :access_token if ActionAgent.encrypt_credentials

    validates :access_token, :github_user_id, :login, presence: true
    # One connection per owner; which column that means depends on the
    # configured mode, so it is checked at validation time.
    validate :unique_within_owner

    # JSON columns carry no default on MySQL or SQLite (see the migration), so
    # an unset column reads as nil.
    def repositories
      Array(super)
    end

    def repository_names
      repositories.map { |repo| repo["full_name"] }
    end

    def repository(full_name)
      repositories.find { |repo| repo["full_name"].casecmp?(full_name.to_s) }
    end

    def client
      GithubClient.new(access_token)
    end

    # The checkout a sandbox backend clones: repository, ref, and an
    # authenticated HTTPS clone URL. Carries the token — hand it to a backend,
    # never to a response.
    def checkout_spec(full_name, ref: nil)
      repo = repository(full_name) or raise ArgumentError, "#{full_name} is not an available repository"

      {
        repository: repo["full_name"],
        ref: ref.presence || repo["default_branch"],
        clone_url: "https://github.com/#{repo["full_name"]}.git",
        username: "x-access-token",
        token: access_token
      }
    end

    def as_summary
      {
        login: login,
        avatar_url: avatar_url,
        scopes: scopes.to_s.split(/[\s,]+/).reject(&:blank?),
        repositories: repositories,
        connected_at: created_at&.iso8601,
        updated_at: updated_at&.iso8601
      }
    end

    private

    def unique_within_owner
      siblings = self.class.for_owner(owner)
      siblings = siblings.where.not(id: id) if persisted?
      errors.add(:base, "GitHub is already connected") if siblings.exists?
    end
  end
end
