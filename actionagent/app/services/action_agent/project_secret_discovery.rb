# frozen_string_literal: true

module ActionAgent
  # Used to find the environment variables a repository expects before its
  # first boot, so the project's secrets form can ask for all of them at
  # once. Deterministic and model-free: the same files at the same commit give
  # the same names. Read through GitHub's contents API:
  #
  #   .env.example, .env.sample   every NAME= line
  #   .activeagents/sandbox.yml   its `secrets:` key, a list of names or a
  #                               mapping of names to descriptions
  #   config/**, lib/**           ENV.fetch("NAME") and ENV["NAME"] call sites
  #                               in Ruby, YAML and ERB files, at most
  #                               MAX_SCANNED_FILES of them in path order
  #
  # Variables Rails or the sandbox sets (RUNTIME_VARIABLES, and the names a
  # ProjectSecret may not take) are left out.
  class ProjectSecretDiscovery
    ENV_FILES = %w[.env.example .env.sample].freeze
    SANDBOX_CONFIG = LocalSandboxBackend::Config::PATH
    SCANNED = %r{\A(?:config|lib)/[^\0]+\.(?:rb|ya?ml|erb)\z}
    MAX_SCANNED_FILES = 40
    MAX_SCANNED_BYTES = 128 * 1024
    # Where a variable was found, listed up to this many places.
    MAX_SOURCES = 5
    ENV_FILE_LINE = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/
    NAME = "[A-Za-z_][A-Za-z0-9_]*"
    # ENV.fetch("NAME") with no default and no block: the app cannot boot
    # without it.
    REQUIRED_FETCH = /ENV\.fetch\(\s*["'](#{NAME})["']\s*\)(?!\s*(?:\{|do\b))/
    ANY_FETCH = /ENV\.fetch\(\s*["'](#{NAME})["']/
    INDEX = /ENV\[\s*["'](#{NAME})["']\s*\]/
    RUNTIME_VARIABLES = %w[
      CI HOME HOSTNAME JOB_CONCURRENCY LANG PIDFILE PORT RACK_ENV RAILS_ENV RAILS_LOG_LEVEL RAILS_LOG_TO_STDOUT
      RAILS_MAX_THREADS RAILS_MIN_THREADS RAILS_SERVE_STATIC_FILES SOLID_QUEUE_IN_PUMA TZ WEB_CONCURRENCY
    ].freeze

    # @param client [GithubClient]
    # @param repository [String] owner/name
    # @param ref [String] the branch, tag or commit to read
    def self.call(client, repository:, ref:)
      new(client, repository: repository, ref: ref).call
    end

    def initialize(client, repository:, ref:)
      @client = client
      @repository = repository
      @ref = ref
      @found = {}
    end

    # @return [Hash]
    #   variables  [{ name:, required:, sources: [String] (at most
    #              MAX_SOURCES), description:, organization_key: provider or
    #              nil }], sorted by name
    #   scanned    the paths read for ENV call sites
    #   truncated  whether files were left unread (more than
    #              MAX_SCANNED_FILES, or GitHub truncated the file listing)
    def call
      ENV_FILES.each { |path| scan_env_file(path) }
      scan_sandbox_config
      listing = @client.tree(@repository, ref: @ref)
      candidates = listing[:paths].select { |entry| SCANNED.match?(entry[:path]) && entry[:size] <= MAX_SCANNED_BYTES }
        .sort_by { |entry| entry[:path] }
      scanned = candidates.first(MAX_SCANNED_FILES).map { |entry| entry[:path] }
      scanned.each { |path| scan_source(path) }

      {
        variables: @found.values.sort_by { |variable| variable[:name] }.map do |variable|
          variable.merge(sources: variable[:sources].uniq.first(MAX_SOURCES),
            organization_key: ProjectSecret::ORGANIZATION_KEY_PROVIDERS[variable[:name]])
        end,
        scanned: scanned,
        truncated: listing[:truncated] || candidates.size > MAX_SCANNED_FILES,
        ref: @ref
      }
    end

    private

    def scan_env_file(path)
      text = @client.file(@repository, path, ref: @ref) or return

      text.each_line.with_index(1) do |line, number|
        name = line[ENV_FILE_LINE, 1]
        note(name, "#{path}:#{number}") if name
      end
    end

    def scan_sandbox_config
      text = @client.file(@repository, SANDBOX_CONFIG, ref: @ref) or return

      data = YAML.safe_load(text, aliases: false)
      entries = data.is_a?(Hash) ? data["secrets"] : nil
      case entries
      when Array then entries.each { |name| note(name.to_s, SANDBOX_CONFIG, required: true) }
      when Hash then entries.each { |name, description| note(name.to_s, SANDBOX_CONFIG, required: true, description: description) }
      end
    rescue Psych::Exception
      nil
    end

    def scan_source(path)
      text = @client.file(@repository, path, ref: @ref) or return

      required = text.scan(REQUIRED_FETCH).flatten.to_set
      text.each_line.with_index(1) do |line, number|
        (line.scan(ANY_FETCH) + line.scan(INDEX)).flatten.each do |name|
          note(name, "#{path}:#{number}", required: required.include?(name))
        end
      end
    end

    def note(name, source, required: false, description: nil)
      return unless SandboxBootSpec::ENV_NAME.match?(name)
      return if RUNTIME_VARIABLES.include?(name) || ProjectSecret.refused_name?(name)

      entry = @found[name] ||= { name: name, required: false, sources: [], description: nil }
      entry[:required] ||= required
      entry[:sources] << source
      entry[:description] ||= description.to_s.truncate(200).presence if description.is_a?(String)
    end
  end
end
