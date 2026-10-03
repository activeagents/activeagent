# frozen_string_literal: true

module ActionAgent
  # Used to decide whether a repository can become a project before any
  # sandbox exists, from files read through GitHub's contents API: its
  # Gemfile.lock, .ruby-version, config/application.rb, config/database.yml
  # and Gemfile. It applies the requirements a bootstrap boot's own preflight
  # applies after checkout (LocalSandboxBackend), so a repository refused
  # here would be refused there.
  #
  # Nothing of the repository runs: the lock is parsed with Bundler's parser,
  # and the other files are only matched against.
  class ProjectPreflight
    STATUSES = %w[supported bootstrap unsupported].freeze
    SUMMARIES = {
      "supported" => "Supported",
      "bootstrap" => "Supported: installs the engine in the sandbox"
    }.freeze
    # Gems whose service a sandbox does not run, with the service's name.
    SERVICE_GEMS = {
      "redis" => "Redis",
      "sidekiq" => "Redis (for Sidekiq)",
      "resque" => "Redis (for Resque)",
      "elasticsearch" => "Elasticsearch",
      "elasticsearch-model" => "Elasticsearch",
      "searchkick" => "Elasticsearch or OpenSearch (for Searchkick)",
      "opensearch-ruby" => "OpenSearch"
    }.freeze
    ERB_TAG = /<%.*?%>/m

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
    end

    # @return [Hash] with string keys:
    #   status            one of STATUSES
    #   summary           what the picker shows: SUMMARIES' text, or the
    #                     first reason the repository is not supported
    #   reasons           why it is not supported (empty otherwise)
    #   warnings          services and databases the sandbox may lack
    #   engine            whether the Gemfile.lock locks actionagent
    #   ruby, ruby_source the Ruby it needs and where that was read
    #   railties, activeagent, actionagent   the locked versions, or nil
    #   database_adapters the adapters config/database.yml names
    #   services          what SERVICE_GEMS found
    #   ref, checked_at
    def call
      lock_text = read("Gemfile.lock")
      facts = lock_text ? lock_facts(lock_text) : nil
      ruby, ruby_source = ruby_requirement(facts)
      railties = facts&.dig("gems", "railties")
      reasons = refusals(lock_text, facts, ruby, ruby_source, railties)
      adapters = database_adapters
      services = required_services(facts)
      engine = facts&.dig("gems", "actionagent").present?
      status = if reasons.any? then "unsupported" elsif engine then "supported" else "bootstrap" end

      {
        "status" => status,
        "summary" => reasons.first || SUMMARIES.fetch(status),
        "reasons" => reasons,
        "warnings" => warnings(adapters, services),
        "engine" => engine,
        "ruby" => ruby,
        "ruby_source" => ruby_source,
        "railties" => railties,
        "activeagent" => facts&.dig("gems", "activeagent"),
        "actionagent" => facts&.dig("gems", "actionagent"),
        "database_adapters" => adapters,
        "services" => services,
        "ref" => @ref,
        "checked_at" => Time.current.iso8601
      }
    end

    private

    def read(path)
      @files ||= {}
      return @files[path] if @files.key?(path)

      @files[path] = @client.file(@repository, path, ref: @ref)
    end

    def refusals(lock_text, facts, ruby, ruby_source, railties)
      return [ "#{@repository} has no Gemfile.lock at its root: a sandbox needs a bundled Rails app" ] if lock_text.nil?
      return [ "#{@repository}'s Gemfile.lock could not be read" ] if facts.nil?

      reasons = []
      if ruby && below?(ruby, SandboxBootSpec::MINIMUM_RUBY)
        reasons << "#{@repository} needs Ruby #{ruby} (#{ruby_source}); the engine needs Ruby #{SandboxBootSpec::MINIMUM_RUBY} or later"
      end
      if railties.nil?
        reasons << "#{@repository}'s Gemfile.lock locks no railties: a sandbox needs a Rails app"
      elsif below?(railties, SandboxBootSpec::MINIMUM_RAILTIES)
        reasons << "#{@repository} locks railties #{railties}; the engine needs Rails #{SandboxBootSpec::MINIMUM_RAILTIES} or later"
      end
      if read("config/application.rb").nil?
        reasons << "#{@repository} has no config/application.rb at its root: a sandbox needs the Rails app at the repository root"
      end
      reasons
    end

    # { "ruby" => "3.3.6" or nil, "gems" => { name => version } }, or nil
    # when the lock does not parse.
    def lock_facts(text)
      parser = ::Bundler::LockfileParser.new(text)
      gems = parser.specs.each_with_object({}) { |spec, all| all[spec.name] ||= spec.version.to_s }
      { "ruby" => parser.ruby_version.to_s[/\d+\.\d+(?:\.\d+)?/], "gems" => gems }
    rescue StandardError
      nil
    end

    def ruby_requirement(facts)
      return [ facts["ruby"], "Gemfile.lock" ] if facts&.dig("ruby")

      version = read(".ruby-version").to_s.lines.first.to_s.strip.delete_prefix("ruby-")[/\A\d+\.\d+(?:\.\d+)?/]
      version ? [ version, ".ruby-version" ] : [ nil, nil ]
    end

    def below?(version, minimum)
      Gem::Version.correct?(version) && Gem::Version.new(version) < minimum
    end

    def database_adapters
      text = read("config/database.yml").to_s.gsub(ERB_TAG, "")
      text.scan(/^[ \t]*adapter:[ \t]*["']?([A-Za-z0-9_]+)/).flatten.uniq
    end

    def required_services(facts)
      gemfile = read("Gemfile").to_s
      named = gemfile.scan(/^\s*gem\s+["']([A-Za-z0-9_.-]+)["']/).flatten
      locked = facts ? facts["gems"].keys : []
      (named | locked).filter_map { |gem| SERVICE_GEMS[gem] }.uniq.sort
    end

    def warnings(adapters, services)
      known = LocalSandboxDatabases::FILE_ADAPTERS + LocalSandboxDatabases::SERVER_ADAPTERS
      unknown = adapters - known
      notes = services.map { |service| "The app uses #{service}, which a sandbox does not run: features that need it may fail." }
      if unknown.any?
        notes << "config/database.yml names #{unknown.join(", ")}, which a local sandbox cannot give databases of its own."
      end
      notes
    end
  end
end
