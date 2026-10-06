# frozen_string_literal: true

module ActionAgent
  module Api
    # Who may decide a project's secrets and the code that reads them. Each
    # method answers whether the signed-in user may, and renders the 403
    # first when not, so a caller returns unless it is true.
    #
    # :manage_project_secrets is always asked about a ProjectSecret, and
    # :manage_credentials about the ProviderKey a secret hands over.
    module ProjectSecretAuthorization
      # The sources a person may give a secret. A value that is not secret
      # (ProjectSecret source "setup_assistant") is set only by the setup
      # assistant.
      PERSON_SECRET_SOURCES = %w[entered organization_key].freeze

      private

      # Whether every one of +entries+ names a source a person may give, or
      # none. Renders 422 first when not.
      def secret_sources_allowed!(entries)
        refused = entries.find do |entry|
          source = entry.respond_to?(:permit) || entry.is_a?(Hash) ? entry[:source] || entry["source"] : nil
          source.present? && !PERSON_SECRET_SOURCES.include?(source.to_s)
        end
        return true if refused.nil?

        render json: { error: "A secret's source must be one of #{PERSON_SECRET_SOURCES.join(", ")}", code: "invalid_source" },
          status: :unprocessable_entity
        false
      end

      # Setting +secret+ needs :manage_project_secrets. A secret that takes
      # the organization's stored provider key also needs
      # :manage_credentials, because the repository's code can then read a
      # key the provider keys API never reveals.
      def authorize_secret!(secret)
        return false unless authorize_action!(:manage_project_secrets, secret)

        key = secret.organization_key? ? secret.organization_provider_key : nil
        key.nil? || authorize_action!(:manage_credentials, key)
      end

      # Handing +project+'s secrets to other code, such as the code at a new
      # ref, needs what setting each of them needs.
      def authorize_secret_handover!(project)
        project.secrets.to_a.all? { |secret| authorize_secret!(secret) }
      end

      # Deleting +project+ deletes its secrets, which needs
      # :manage_project_secrets for each.
      def authorize_secrets_removal!(project)
        project.secrets.to_a.all? { |secret| authorize_action!(:manage_project_secrets, secret) }
      end
    end
  end
end
