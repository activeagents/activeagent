# frozen_string_literal: true

module ActionAgent
  # Defense in depth for custom adapters and accidental copies into app/.
  # The actual credentials live outside the checkout and are never read.
  #
  # Only what a copy of them would look like is excluded: a Claude Code
  # credentials file anywhere, and the sandbox's own config directories at
  # the checkout's root. A repository's .claude/ settings, or an app's
  # lib/claude/ code, stay in diffs, file reads and pull requests.
  module SandboxCredentialPaths
    DIRECTORIES = %w[claude claude-api claude-home claude-login].freeze
    FILE = ".credentials.json"
    module_function

    def protected?(path)
      parts = path.to_s.delete_prefix("./").split("/")
      DIRECTORIES.any? { |name| parts.first.to_s.casecmp?(name) } || parts.any? { |part| part.casecmp?(FILE) }
    end

    def pathspecs
      DIRECTORIES.map { |name| ":(exclude,glob,icase)#{name}/**" } +
        [ ":(exclude,glob,icase)**/#{FILE}", ":(exclude,glob,icase)#{FILE}" ]
    end
  end
end
