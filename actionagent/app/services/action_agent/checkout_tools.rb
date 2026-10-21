# frozen_string_literal: true

module ActionAgent
  # The toolbox capabilities that work in a checkout: terminal (run_command),
  # filesystem (list_files, read_file, write_file), edit (edit_file) and
  # database (query_database). Each acts on the checkout sandbox the run was
  # given (AgentRun#sandbox_id — the runner's and an evaluation's
  # `sandbox_id`), through SandboxOrchestrator, so they reach exactly what a
  # Claude Code session in that checkout reaches.
  #
  # A run given no checkout gets an error saying how to give it one, rather
  # than a tool that silently does nothing. Results and errors are returned
  # as hashes for the model to read.
  class CheckoutTools
    FUNCTIONS = %w[run_command list_files read_file write_file edit_file query_database].freeze

    # Rows query_database returns at most, and how long it may take, Rails
    # boot included.
    MAX_QUERY_ROWS = 200
    QUERY_TIMEOUT = 90
    # The line the query script's JSON follows, so whatever the app prints
    # while booting is not mistaken for the result.
    QUERY_MARKER = "__ACTION_AGENT_QUERY__"

    NO_CHECKOUT = "This run has no checkout sandbox. Choose one under Checkout on the agent's Run page " \
      "(or run an evaluation against one), then run again."

    def self.function?(name)
      FUNCTIONS.include?(name.to_s)
    end

    # @param sandbox [SandboxSession, nil] the run's checkout, or nil
    def initialize(sandbox, orchestrator: nil)
      @sandbox = sandbox
      @orchestrator = orchestrator
    end

    # @return [Hash]
    def call(name, kwargs)
      return { error: "Unknown tool: #{name}" } unless self.class.function?(name)
      return { error: NO_CHECKOUT } unless @sandbox
      unless @sandbox.ready? || @sandbox.running?
        return { error: "The checkout sandbox #{@sandbox.session_id} is #{@sandbox.status}; start it again and rerun" }
      end

      args = kwargs.to_h.symbolize_keys
      case name.to_s
      when "run_command" then run_command(**args.slice(:command, :timeout_seconds))
      when "list_files" then list_files(**args.slice(:path))
      when "read_file" then read_file(**args.slice(:path))
      when "write_file" then write_file(**args.slice(:path, :content))
      when "edit_file" then edit_file(**args.slice(:path, :old_text, :new_text))
      when "query_database" then query_database(**args.slice(:sql))
      end
    rescue ArgumentError, SandboxOrchestrator::UnsupportedBackendError, LocalSandboxBackend::Error => e
      { error: e.message }
    end

    def run_command(command:, timeout_seconds: nil)
      orchestrator.run_command(@sandbox, command.to_s, timeout: timeout_seconds&.to_i)
    end

    def list_files(path: nil)
      orchestrator.list_files(@sandbox, path.presence)
    end

    def read_file(path:)
      content = orchestrator.read_file(@sandbox, path.to_s)
      return { error: "#{path} does not exist in the checkout" } if content.nil?

      text = content.dup.force_encoding(Encoding::UTF_8)
      return { error: "#{path} is not a text file" } unless text.valid_encoding?

      { path: path, content: text }
    end

    def write_file(path:, content:)
      orchestrator.write_file(@sandbox, path.to_s, content.to_s)
    end

    # One exact replacement, the edit a model can say precisely: +old_text+
    # must appear exactly once, so the edit lands where it was meant to.
    def edit_file(path:, old_text:, new_text:)
      current = read_file(path: path)
      return current if current[:error]

      occurrences = current[:content].scan(old_text.to_s).size
      return { error: "old_text is empty" } if old_text.to_s.empty?
      return { error: "old_text was not found in #{path}" } if occurrences.zero?
      return { error: "old_text appears #{occurrences} times in #{path}; include more context so it appears once" } if occurrences > 1

      written = orchestrator.write_file(@sandbox, path.to_s, current[:content].sub(old_text.to_s) { new_text.to_s })
      written.merge(replaced: 1)
    end

    # Runs +sql+ in the checkout's own Rails environment, against the
    # database its boot provisioned, inside a read-only transaction that is
    # rolled back (PostgreSQL, MySQL), or on a query_only connection (SQLite). The SQL travels base64-encoded inside the script, so
    # nothing in it reaches the shell.
    def query_database(sql:)
      return { error: "No SQL to run" } if sql.to_s.strip.empty?

      result = orchestrator.run_command(@sandbox, query_command(sql.to_s), timeout: QUERY_TIMEOUT)
      line = result[:output].to_s.lines.reverse.find { |candidate| candidate.start_with?(QUERY_MARKER) }
      unless line
        return { error: "The query did not run", exit_status: result[:exit_status], output: result[:output].to_s.last(4_000) }
      end

      JSON.parse(line.delete_prefix(QUERY_MARKER))
    rescue JSON::ParserError
      { error: "The query's result could not be read", output: result[:output].to_s.last(4_000) }
    end

    private

    def orchestrator
      @orchestrator ||= SandboxOrchestrator.new
    end

    def query_command(sql)
      encoded = [ sql ].pack("m0")
      script = <<~RUBY
        sql = "#{encoded}".unpack1("m0").force_encoding("UTF-8")
        connection = ActiveRecord::Base.connection
        adapter = connection.adapter_name.downcase
        out = nil
        read = lambda do
          result = connection.select_all(sql)
          out = { columns: result.columns, rows: result.rows.first(#{MAX_QUERY_ROWS}), row_count: result.rows.size, truncated: result.rows.size > #{MAX_QUERY_ROWS} }
        end
        begin
          if adapter.include?("sqlite")
            # Rails opens SQLite transactions with BEGIN IMMEDIATE, which
            # query_only refuses; query_only alone keeps the connection from writing.
            connection.execute("PRAGMA query_only = ON")
            read.call
          else
            connection.execute("SET SESSION TRANSACTION READ ONLY") if adapter.match?(/mysql|trilogy/)
            connection.transaction do
              connection.execute("SET TRANSACTION READ ONLY") if adapter.include?("postg")
              read.call
              raise ActiveRecord::Rollback
            end
          end
        rescue => e
          out = { error: e.message.to_s[0, 2000] }
        end
        puts "#{QUERY_MARKER}" + out.to_json
      RUBY

      "bin/rails runner #{Shellwords.escape(script)}"
    end
  end
end
