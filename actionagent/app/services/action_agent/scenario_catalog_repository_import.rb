# frozen_string_literal: true

module ActionAgent
  # Imports the scenario catalogs a connected repository keeps, read through
  # GitHub's contents API at a ref: every `.yml` under +path+
  # (`.activeagents/evals` by default, where the install pull request writes
  # a project's suite), or the one file +path+ names. Each file is a
  # catalog; its source is recorded as "owner/name@ref:path", so a re-import
  # of the same ref finds it again, and a pull request's branch can carry
  # the scenarios that accept it.
  class ScenarioCatalogRepositoryImport
    DEFAULT_PATH = ".activeagents/evals"
    MAX_FILES = 50
    EXTENSIONS = %w[.yml .yaml].freeze

    def initialize(owner:, connection:, repository:, ref: nil, path: nil, agents: nil, projects: nil, mode: "replace")
      @owner = owner
      @connection = connection
      @repository = repository.to_s
      @ref = ref.to_s.presence
      @path = path.to_s.presence || DEFAULT_PATH
      @agents = agents
      @projects = projects
      @mode = mode
    end

    # @return [Array<ScenarioCatalog>] the imported catalogs, one per file
    def call
      imports.map(&:call)
    end

    # What #call would change, one ScenarioCatalogImport#preview per file,
    # each with the file's source_path.
    # @return [Array<Hash>]
    def preview
      imports.map { |import| import.preview.merge(source_path: import.source_path) }
    end

    private

    # One ScenarioCatalogImport per catalog file at the ref.
    def imports
      client = @connection.client
      ref = @ref || default_branch(client)
      files = catalog_files(client, ref)
      if files.empty?
        raise ScenarioCatalogImport::Invalid, "#{@repository} at #{ref} has no catalog at #{@path}: " \
          "add a .yml file there, or name the file to read"
      end

      files.first(MAX_FILES).filter_map do |file_path|
        content = client.file(@repository, file_path, ref: ref)
        next if content.nil?

        ScenarioCatalogImport.new(
          owner: @owner, document: content, name: File.basename(file_path, File.extname(file_path)),
          source_kind: "repository", source_path: "#{@repository}@#{ref}:#{file_path}",
          agents: @agents, projects: @projects, mode: @mode
        )
      end
    rescue GithubClient::Error => e
      raise ScenarioCatalogImport::Invalid, "GitHub refused reading #{@repository}: #{e.message}"
    end

    def default_branch(client)
      @connection.repository(@repository)&.dig("default_branch").presence || client.repository(@repository)["default_branch"]
    end

    # The .yml files at @path: the file itself, or the files directly under
    # the directory, in name order.
    def catalog_files(client, ref)
      return [ @path ] if EXTENSIONS.include?(File.extname(@path))

      directory = @path.chomp("/")
      client.tree(@repository, ref: ref)[:paths]
        .map { |entry| entry[:path] }
        .select { |entry| entry.start_with?("#{directory}/") && EXTENSIONS.include?(File.extname(entry)) && !entry.delete_prefix("#{directory}/").include?("/") }
        .sort
    end
  end
end
