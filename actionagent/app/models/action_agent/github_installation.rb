# frozen_string_literal: true

module ActionAgent
  # A GitHub App installation an owner linked (Settings -> Integrations), and
  # the repositories they made available on it.
  #
  # Nothing here is a credential. A checkout or a repository listing mints an
  # installation token when it needs one, limited to one repository where it
  # can be and to the permission that step needs, and the token is never
  # stored. +repositories+ holds only what GitHub listed for the installation
  # when the owner chose them (see Api::GithubInstallationsController#update).
  #
  # The +github_account_*+ columns describe the GitHub user or organization
  # the App is installed on, and are unrelated to the owner's +account_id+.
  # An installation is linked to one owner at most: +installation_id+ is
  # unique across every owner.
  class GithubInstallation < ApplicationRecord
    include Ownable
    owned_by :account, :user

    ACCOUNT_TYPES = %w[User Organization].freeze
    # The permission a checkout's fetch needs.
    CHECKOUT_PERMISSIONS = { contents: "read" }.freeze
    # The permission listing an installation's repositories needs.
    LISTING_PERMISSIONS = { metadata: "read" }.freeze

    validates :installation_id, :github_account_id, :github_account_login, presence: true
    validates :installation_id, uniqueness: true
    validates :github_account_type, inclusion: { in: ACCOUNT_TYPES }

    # JSON columns carry no default on MySQL or SQLite (see the migration), so
    # an unset column reads as nil.
    def repositories
      Array(super)
    end

    def permissions
      value = super
      value.is_a?(Hash) ? value : {}
    end

    def repository_names
      repositories.map { |repo| repo["full_name"] }
    end

    def repository(full_name)
      repositories.find { |repo| repo["full_name"].casecmp?(full_name.to_s) }
    end

    # Whether GitHub will still mint tokens for this installation, as far as
    # the dashboard last heard: false once a mint found it removed or
    # suspended, until a later mint succeeds or it is linked again.
    def usable?
      removed_at.nil? && suspended_at.nil?
    end

    # Mints an installation token limited to +permissions+ and, when given,
    # +repository_ids+. A refusal because the installation was removed or
    # suspended is recorded on the row before it is raised again, and a
    # successful mint clears that record, since GitHub mints for neither.
    #
    # @raise [GithubClient::InstallationUnavailable]
    # @return [String] the token, which the caller must not store
    def mint_token!(permissions:, repository_ids: nil)
      token = GithubClient.mint_installation_token(installation_id, permissions: permissions, repository_ids: repository_ids)
      update_columns(removed_at: nil, suspended_at: nil) if persisted? && !usable?
      token
    rescue GithubClient::InstallationUnavailable => e
      mark_unavailable!(e.reason)
      raise
    end

    # The checkout of +full_name+ a sandbox backend clones, without a token.
    # Reading it calls nothing; #checkout_spec! is the one that mints.
    #
    # @raise [ArgumentError] when +full_name+ is not a selected repository
    def checkout_spec(full_name, ref: nil, token: nil)
      repo = repository(full_name) or raise ArgumentError, "#{full_name} is not an available repository"

      {
        repository: repo["full_name"],
        ref: ref.presence || repo["default_branch"],
        clone_url: "https://github.com/#{repo["full_name"]}.git",
        username: "x-access-token",
        token: token
      }
    end

    # #checkout_spec with a freshly minted token that reads the contents of
    # that one repository. Carries the token: hand it to a backend, never to
    # a response.
    def checkout_spec!(full_name, ref: nil)
      repo = repository(full_name) or raise ArgumentError, "#{full_name} is not an available repository"

      token = mint_token!(permissions: CHECKOUT_PERMISSIONS, repository_ids: [ repo["id"] ])
      checkout_spec(full_name, ref: ref, token: token)
    end

    # A client for the installation's repository listing, with a token that
    # can read repository metadata and nothing else.
    def listing_client
      GithubClient.new(mint_token!(permissions: LISTING_PERMISSIONS))
    end

    # Records what GitHub reported about the installation when it was linked.
    def assign_from_github(installation)
      account = installation["account"] || {}
      assign_attributes(
        github_account_id: account["id"],
        github_account_login: account["login"],
        github_account_type: account["type"],
        repository_selection: installation["repository_selection"],
        permissions: installation["permissions"].is_a?(Hash) ? installation["permissions"] : {},
        suspended_at: installation["suspended_at"],
        removed_at: nil
      )
    end

    def as_summary
      {
        id: id,
        installation_id: installation_id,
        account_login: github_account_login,
        account_type: github_account_type,
        repository_selection: repository_selection,
        permissions: permissions,
        repositories: repositories,
        status: status,
        settings_url: settings_url,
        linked_at: created_at&.iso8601,
        updated_at: updated_at&.iso8601
      }
    end

    # "active", "suspended" or "removed".
    def status
      return "removed" if removed_at
      return "suspended" if suspended_at

      "active"
    end

    # Where the installation's repository access is changed on GitHub.
    def settings_url
      if github_account_type == "Organization"
        "https://github.com/organizations/#{github_account_login}/settings/installations/#{installation_id}"
      else
        "https://github.com/settings/installations/#{installation_id}"
      end
    end

    private

    def mark_unavailable!(reason)
      column = reason == :suspended ? :suspended_at : :removed_at
      update_column(column, Time.current) if persisted? && self[column].nil?
    end
  end
end
