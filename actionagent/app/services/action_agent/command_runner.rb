# frozen_string_literal: true

require "open3"
require "shellwords"

module ActionAgent
  # Runs an external command as an argv array, never as a shell string.
  #
  # Everything a code session shells out to (the coi CLI, ssh, git through
  # coi) carries values a user typed: a repository, a branch, a model name, a
  # task. Passing those through a shell would make each one an injection
  # point, so this runner spawns the argv directly and lets the operating
  # system pass the arguments verbatim.
  #
  # A remote runner prefixes every argv with an ssh invocation, which is the
  # one place a shell reappears: ssh concatenates its arguments and the login
  # shell re-splits them. The prefix therefore escapes each element with
  # Shellwords before handing it over, so the remote shell sees exactly the
  # argv given here.
  #
  # The process is spawned into its own process group so a timeout kills the
  # whole tree rather than leaving a container build orphaned.
  class CommandRunner
    Result = Struct.new(:stdout, :stderr, :exit_code, :duration_ms, :timed_out, keyword_init: true) do
      def success? = exit_code.zero? && !timed_out

      def timed_out? = timed_out == true

      # stdout with stderr appended when it carried anything, which is what
      # a transcript should show: the tool's own output, then why it stopped.
      def output
        return stdout if stderr.blank?

        [ stdout.presence, "--- stderr ---", stderr ].compact.join("\n")
      end
    end

    DEFAULT_TIMEOUT = 900

    # @param prefix [Array<String>] argv placed before every command (ssh)
    # @param timeout [Integer] seconds before the process group is killed
    def initialize(prefix: [], timeout: DEFAULT_TIMEOUT)
      @prefix = Array(prefix).map(&:to_s)
      @timeout = timeout.to_i.positive? ? timeout.to_i : DEFAULT_TIMEOUT
    end

    attr_reader :prefix, :timeout

    # @param argv [Array<String>] the command and its arguments
    # @param env [Hash] environment variables for the child process. With a
    #   prefix (ssh) these cannot be passed through the child's environment,
    #   so they are exported by the remote shell instead.
    # @param stdin [String, nil] written to the child's standard input, which
    #   is how secrets travel: a value on stdin never appears in argv, and so
    #   never in `ps` or in a shell history.
    # @param timeout [Integer, nil] overrides this runner's timeout
    # @return [Result]
    def call(argv, env: {}, chdir: nil, stdin: nil, timeout: nil)
      command = full_argv(argv, env: env)
      limit = (timeout || @timeout).to_i
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      spawn_env = @prefix.any? ? {} : env.transform_keys(&:to_s).transform_values(&:to_s)
      options = { pgroup: true }
      options[:chdir] = chdir.to_s if chdir.present?

      stdout, stderr, status, timed_out = capture(command, spawn_env, options, stdin, limit)

      Result.new(
        stdout: stdout,
        stderr: stderr,
        exit_code: status,
        duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
        timed_out: timed_out
      )
    end

    # The command as a copyable one-liner, for the "attach" hint the UI
    # shows. Escaped, because a person pastes this into a shell.
    def display_command(argv, env: {})
      full_argv(argv, env: env).shelljoin
    end

    private

    # Locally: env goes to the child process and argv is spawned as given.
    # Remotely: ssh gets one command string, so the environment is exported
    # by the remote shell and every argument is escaped for it.
    def full_argv(argv, env: {})
      argv = Array(argv).map(&:to_s)
      return argv if @prefix.empty?

      exports = env.map { |key, value| "#{key}=#{Shellwords.escape(value.to_s)}" }
      remote = (exports + argv.map { |part| Shellwords.escape(part) }).join(" ")
      @prefix + [ remote ]
    end

    def capture(command, env, options, stdin, limit)
      out_reader = nil
      err_reader = nil

      Open3.popen3(env, *command, **options) do |stdin_io, stdout_io, stderr_io, wait_thread|
        if stdin
          begin
            stdin_io.write(stdin)
          rescue Errno::EPIPE
            # The child exited before reading; its status says why.
          end
        end
        stdin_io.close

        # Read both pipes on their own threads: a child that fills the stderr
        # buffer while this side reads stdout would otherwise deadlock.
        out_reader = Thread.new { stdout_io.read.to_s }
        err_reader = Thread.new { stderr_io.read.to_s }

        if wait_thread.join(limit).nil?
          kill_group(wait_thread.pid)
          wait_thread.join(5)
          return [ out_reader.value.scrub, err_reader.value.scrub, 124, true ]
        end

        [ out_reader.value.scrub, err_reader.value.scrub, wait_thread.value.exitstatus.to_i, false ]
      end
    rescue Errno::ENOENT => e
      [ "", "command not found: #{e.message}", 127, false ]
    ensure
      out_reader&.kill if out_reader&.alive?
      err_reader&.kill if err_reader&.alive?
    end

    def kill_group(pid)
      Process.kill("TERM", -pid)
      sleep 0.2
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      # Already gone, or not ours to kill.
      nil
    end
  end
end
