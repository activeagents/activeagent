# frozen_string_literal: true

require "json"
require "optparse"
require_relative "version"

module ActiveAgent
  # The `activeagent` executable: a dashboard's evaluations, scenario
  # catalogs, agents and traces from a terminal or a CI job, over HTTP with a
  # dashboard API key. Plain Ruby (OptionParser and Net::HTTP); it loads
  # neither Rails nor the framework, so it starts fast and runs anywhere the
  # gem is installed.
  #
  #   activeagent login --url https://ops.example.com/activeagents --key aa_...
  #   activeagent evals run "Support orders" --wait --min-pass-rate 0.8
  #
  # Every command answers through an API-key-authenticated endpoint: the MCP
  # facade's dashboard tools (<mount>/mcp) or the report collector
  # (<mount>/api/evaluation_reports). A command whose dashboard route only
  # takes a browser session today says so and exits EXIT_UNAVAILABLE rather
  # than scraping the UI's API.
  #
  # CLI.start returns the exit code rather than exiting, so it can be called
  # from Ruby and tested in process.
  class CLI
    EXIT_SUCCESS = 0
    # A request failed or the dashboard refused it.
    EXIT_FAILURE = 1
    # The command line was wrong.
    EXIT_USAGE = 2
    # No dashboard URL or key to use.
    EXIT_CONFIG = 3
    # An evaluation run failed, or passed fewer scenarios than --min-pass-rate.
    EXIT_GATE = 4
    # The dashboard has no API-key route for the command yet.
    EXIT_UNAVAILABLE = 5

    # Every failure a command reports: the message is printed and the exit
    # code returned. +status+ is the HTTP status or JSON-RPC code behind it.
    class Error < StandardError
      attr_reader :exit_code, :status

      def initialize(message = nil, exit_code: EXIT_FAILURE, status: nil)
        super(message)
        @exit_code = exit_code
        @status = status
      end
    end

    ISSUE_URL = "https://github.com/activeagents/activeagent/issues/619"

    def self.version
      ActiveAgent::VERSION
    end

    def self.start(argv = ARGV, **options)
      new(**options).run(argv.dup)
    end

    # +sleeper+ and +clock+ let tests drive `evals run --wait` without
    # waiting.
    def initialize(out: $stdout, err: $stderr, input: $stdin, env: ENV, credentials_path: nil,
                   sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @out = out
      @err = err
      @input = input
      @env = env
      @credentials = Credentials.new(credentials_path || Credentials.default_path(env))
      @sleeper = sleeper
      @clock = clock
      @options = {}
    end

    def run(argv)
      global_parser.order!(argv)
      return print_version if @options[:version]

      command = argv.shift
      return print_help(global_parser) if command.nil? || command == "help" || @options[:help]

      dispatch(command, argv)
    rescue OptionParser::ParseError => e
      @err.puts "activeagent: #{e.message}"
      @err.puts "Run `activeagent help` for usage."
      EXIT_USAGE
    rescue Error => e
      @err.puts "activeagent: #{e.message}"
      e.exit_code
    end

    COMMANDS = {
      "login" => "Store a dashboard URL and API key as a profile",
      "logout" => "Remove a stored profile",
      "status" => "Check the URL and keys against the dashboard",
      "evals" => "Evaluations: list, runs, run, report, import",
      "catalogs" => "Scenario catalogs: list, import, export",
      "agents" => "Agents: list, versions",
      "traces" => "Telemetry traces: list",
      "version" => "Print the version"
    }.freeze

    private

    def dispatch(command, argv)
      case command
      when "login" then login(argv)
      when "logout" then logout(argv)
      when "status" then status(argv)
      when "version" then print_version
      when "evals" then subcommand("evals", argv, %w[list runs run report import])
      when "catalogs" then subcommand("catalogs", argv, %w[list import export])
      when "agents" then subcommand("agents", argv, %w[list versions])
      when "traces" then subcommand("traces", argv, %w[list])
      else
        raise Error.new("unknown command '#{command}'. Commands: #{COMMANDS.keys.join(", ")}", exit_code: EXIT_USAGE)
      end
    end

    def subcommand(group, argv, names)
      name = argv.shift
      if name.nil? || %w[help -h --help].include?(name)
        @out.puts "Usage: activeagent #{group} <#{names.join("|")}> [options]"
        return name.nil? ? EXIT_USAGE : EXIT_SUCCESS
      end
      unless names.include?(name)
        raise Error.new("unknown command '#{group} #{name}'. Try: #{names.map { |n| "#{group} #{n}" }.join(", ")}", exit_code: EXIT_USAGE)
      end

      send(:"#{group}_#{name}", argv)
    end

    def global_parser
      @global_parser ||= OptionParser.new do |parser|
        parser.banner = "Usage: activeagent <command> [options]"
        parser.separator ""
        parser.separator "Commands:"
        COMMANDS.each { |name, description| parser.separator format("    %-10s %s", name, description) }
        parser.separator ""
        parser.separator "Options:"
        common_options(parser)
        parser.on("-v", "--version", "Print the version") { @options[:version] = true }
        parser.separator ""
        parser.separator "Environment: ACTIVEAGENT_URL, ACTIVEAGENT_API_KEY, ACTIVEAGENT_INGEST_KEY and"
        parser.separator "ACTIVEAGENT_PROFILE override the stored profile (for CI)."
        parser.separator "Exit codes: 0 ok, 1 failed, 2 usage, 3 not configured, 4 evaluation gate failed,"
        parser.separator "5 not yet available on this dashboard."
      end
    end

    # Options every command takes, before or after the command name.
    def common_options(parser)
      parser.on("--profile NAME", "Use this stored profile (default: ACTIVEAGENT_PROFILE or 'default')") { |value| @options[:profile] = value }
      parser.on("--url URL", "The dashboard mount, e.g. https://ops.example.com/activeagents") { |value| @options[:url] = value }
      parser.on("--json", "Print JSON for scripts instead of tables") { @options[:json] = true }
      parser.on("-h", "--help", "Show help") { @options[:help] = true }
    end

    # Parses +argv+ with the command's own options plus the common ones and
    # returns the remaining positional arguments, printing the command's help
    # and returning nil for --help.
    def parse(argv, banner)
      parser = OptionParser.new do |p|
        p.banner = "Usage: activeagent #{banner}"
        yield p if block_given?
        common_options(p)
      end
      parser.parse!(argv)
      if @options[:help]
        @out.puts parser
        return nil
      end
      argv
    end

    def print_help(parser)
      @out.puts parser
      EXIT_SUCCESS
    end

    def print_version
      @out.puts(@options[:json] ? JSON.generate(version: self.class.version) : "activeagent #{self.class.version}")
      EXIT_SUCCESS
    end

    def profile_name
      @options[:profile] || @env["ACTIVEAGENT_PROFILE"].to_s.then { |name| name.empty? ? "default" : name }
    end

    # The profile's stored values with the environment and --url over them.
    def profile
      stored = @credentials[profile_name]
      if stored.empty? && @options[:profile] && !@env["ACTIVEAGENT_URL"]
        raise Error.new("No profile '#{profile_name}' in #{@credentials.path}; run `activeagent login --profile #{profile_name}`",
                        exit_code: EXIT_CONFIG)
      end

      {
        "url" => @options[:url] || env_value("ACTIVEAGENT_URL") || stored["url"],
        "api_key" => env_value("ACTIVEAGENT_API_KEY") || stored["api_key"],
        "ingest_key" => env_value("ACTIVEAGENT_INGEST_KEY") || stored["ingest_key"]
      }
    end

    def env_value(name)
      value = @env[name].to_s.strip
      value.empty? ? nil : value
    end

    def client
      @client ||= begin
        values = profile
        if values["url"].to_s.empty?
          raise Error.new("No dashboard URL: run `activeagent login --url <mount URL>`, or set ACTIVEAGENT_URL", exit_code: EXIT_CONFIG)
        end
        Client.new(url: values["url"], api_key: values["api_key"], ingest_key: values["ingest_key"])
      end
    end

    # Prints +data+ as JSON with --json, otherwise yields for the human form.
    def emit(data)
      if @options[:json]
        @out.puts JSON.pretty_generate(data)
      else
        yield
      end
      EXIT_SUCCESS
    end

    # Prints +rows+ as aligned columns. +columns+ maps each header to a
    # proc reading a row's cell.
    def table(rows, columns, empty: "Nothing to show.")
      return @out.puts(empty) if rows.empty?

      cells = rows.map { |row| columns.values.map { |reader| cell(reader.call(row)) } }
      widths = columns.keys.each_with_index.map { |header, i| ([ header ] + cells.map { |c| c[i] }).map(&:length).max }
      line = ->(values) { values.each_with_index.map { |value, i| value.ljust(widths[i]) }.join("  ").rstrip }
      @out.puts line.call(columns.keys)
      cells.each { |c| @out.puts line.call(c) }
    end

    def cell(value)
      value.nil? ? "-" : value.to_s.gsub(/[[:space:]\p{C}]+/, " ")
    end

    def unavailable(command, endpoint)
      raise Error.new("`#{command}` is not yet available on this dashboard: it needs an API-key-authenticated " \
                      "#{endpoint}, which only takes a browser session today. See #{ISSUE_URL}.", exit_code: EXIT_UNAVAILABLE)
    end

    def require_argument(argv, name, usage)
      value = argv.shift
      raise Error.new("missing #{name}. Usage: activeagent #{usage}", exit_code: EXIT_USAGE) if value.to_s.empty?
      raise Error.new("unexpected arguments: #{argv.join(" ")}", exit_code: EXIT_USAGE) unless argv.empty?

      value
    end

    def positive_integer(value, name)
      Integer(value, 10).tap { |n| raise ArgumentError unless n.positive? }
    rescue ArgumentError, TypeError
      raise Error.new("#{name} must be a positive integer", exit_code: EXIT_USAGE)
    end

    def list_option(value)
      value.split(",").map(&:strip).reject(&:empty?)
    end
  end
end

require_relative "cli/credentials"
require_relative "cli/client"
require_relative "cli/session_commands"
require_relative "cli/eval_commands"
require_relative "cli/resource_commands"
