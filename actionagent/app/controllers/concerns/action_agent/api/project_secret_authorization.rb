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
      private

      # Setting +secret+ needs :manage_project_secrets. A secret that takes
      # the organization's stored provider key also needs
      # :manage_credentials, because the repository's code can then read a
      # key the provider keys API never reveals.
      def authorize_secret!(secret)
        return false unless authorize_action!(:manage_project_secrets, secret)

        key = secret.organization_key? ? secret.organization_provider_key : nil
        key.nil? || authorize_action!(:manage_credentials, key)
      end
    end
  end
end
