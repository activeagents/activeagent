# frozen_string_literal: true

module ActionAgent
  module SandboxCredentialPaths
    # Defense in depth for custom adapters and accidental copies into app/.
    # The actual credentials live outside the checkout and are never read.
    DIRECTORIES = %w[claude .claude claude-api claude-home claude-login].freeze
    module_function
    def protected?(path)
      path.to_s.split("/").any? { |part| DIRECTORIES.include?(part.downcase) || part.casecmp?(".credentials.json") }
    end
    def pathspecs
      DIRECTORIES.flat_map { |name| [ ":(exclude,glob,icase)#{name}/**", ":(exclude,glob,icase)**/#{name}/**" ] } +
        [ ":(exclude,glob,icase)**/.credentials.json", ":(exclude,glob,icase).credentials.json" ]
    end
  end
end
