# frozen_string_literal: true

require "json"
require "open3"

module ActionAgent
  # Used to install, find and check the browser sidecar the :local sandbox
  # backend runs: the @activeagents/browser-sidecar npm package, versioned
  # with this engine, and the Chromium it drives. Both live under the local
  # sandbox root:
  #
  #   .browser/
  #     node_modules/   the package and its dependencies
  #     browsers/       Chromium (PLAYWRIGHT_BROWSERS_PATH)
  #
  # ActionAgent.browser_sidecar_path names a checkout of the package to run
  # instead, for working on the sidecar; its version is not checked.
  #
  # Nothing here downloads anything except #install!: a start with the
  # sidecar or Chromium missing is refused with the command that installs
  # them (#refusal).
  class BrowserSidecar
    PACKAGE = "@activeagents/browser-sidecar"
    ENTRYPOINT = "bin/browser-sidecar.mjs"
    MINIMUM_NODE = Gem::Version.new("20")
    INSTALL_COMMAND = "bin/rails action_agent:browser:install"
    CHECK_TIMEOUT = 30
    INSTALL_TIMEOUT = 900

    class Error < StandardError; end

    # One thing a browser start needs. +fix+ says how to get it when it is
    # not +ok+.
    Check = Struct.new(:name, :ok, :detail, :fix, keyword_init: true) do
      def message
        ok ? detail : "#{detail}. #{fix}"
      end
    end

    class << self
      # @return [Pathname]
      def root
        ActionAgent.local_sandbox_root.join(".browser")
      end

      # Where Chromium is installed and looked for.
      # @return [Pathname]
      def browsers_path
        root.join("browsers")
      end

      # The configured checkout, or nil to run the installed package.
      # @return [Pathname, nil]
      def checkout
        path = ActionAgent.browser_sidecar_path.presence
        path && Pathname.new(path.to_s).expand_path
      end

      # @return [Pathname]
      def package_dir
        checkout || root.join("node_modules", *PACKAGE.split("/"))
      end

      # The environment the sidecar runs with, on top of a sandbox's
      # sanitized one.
      # @return [Hash{String => String}]
      def environment
        { "PLAYWRIGHT_BROWSERS_PATH" => browsers_path.to_s }
      end

      # The command line that runs the sidecar with +args+.
      # @return [Array<String>]
      def command(*args)
        [ ActionAgent.node_command.to_s, package_dir.join(ENTRYPOINT).to_s, *args ]
      end

      # Whether a sidecar reporting +version+ may run: the engine's own
      # version, or any version from a configured checkout.
      def acceptable_version?(version)
        checkout.present? || version == ActionAgent::VERSION
      end

      # Node, the sidecar and Chromium, each checked. The doctor task prints
      # these; a browser start refuses with the first that is not ok.
      #
      # @return [Array<Check>]
      def checks
        node = node_check
        return [ node ] unless node.ok

        sidecar, report = sidecar_check
        return [ node, sidecar ] unless report

        [ node, sidecar, chromium_check(report) ]
      end

      # Why a browser cannot start on this machine, or nil when it can.
      # @return [String, nil]
      def refusal
        checks.find { |check| !check.ok }&.message
      end

      # Installs the sidecar (npm ci in a checkout, else the package at the
      # engine's version under #root) and its Chromium, writing their output
      # to +io+.
      #
      # @raise [Error] when a step fails
      def install!(io = $stdout)
        if checkout
          run!(io, [ ActionAgent.npm_command.to_s, "ci" ], chdir: checkout)
        else
          FileUtils.mkdir_p(root)
          manifest = root.join("package.json")
          manifest.write(JSON.pretty_generate({ "private" => true, "description" => "The dashboard's browser sidecar" })) unless manifest.exist?
          run!(io, [ ActionAgent.npm_command.to_s, "install", "--no-audit", "--no-fund", "--save-exact", "#{PACKAGE}@#{ActionAgent::VERSION}" ],
            chdir: root)
        end
        run!(io, command("install-browser"), chdir: checkout || root)
      end

      private

      def node_check
        output, status = capture([ ActionAgent.node_command.to_s, "--version" ])
        version = output.to_s[/\Av?(\d+\.\d+\.\d+)/, 1]
        if status&.success? && version && Gem::Version.new(version) >= MINIMUM_NODE
          return Check.new(name: "node", ok: true, detail: "Node.js #{version}")
        end

        Check.new(
          name: "node", ok: false,
          detail: version ? "Node.js #{version} is older than #{MINIMUM_NODE}" : "Node.js was not found (#{ActionAgent.node_command})",
          fix: "Install Node.js #{MINIMUM_NODE} or later, or set ActionAgent.node_command"
        )
      end

      # The sidecar check, and what its `check` command reported (nil when
      # it could not run).
      def sidecar_check
        unless package_dir.join(ENTRYPOINT).file?
          return [ Check.new(name: "sidecar", ok: false, detail: "The browser sidecar is not installed (#{package_dir})",
            fix: "Run #{INSTALL_COMMAND}"), nil ]
        end

        output, status = capture(command("check"))
        report = status&.success? ? parse_report(output) : nil
        unless report
          return [ Check.new(name: "sidecar", ok: false, detail: "The browser sidecar did not run: #{output.to_s.strip.lines.last&.strip}",
            fix: "Run #{INSTALL_COMMAND}"), nil ]
        end

        version = report["version"].to_s
        unless acceptable_version?(version)
          return [ Check.new(name: "sidecar", ok: false,
            detail: "The browser sidecar is version #{version}, and this dashboard needs #{ActionAgent::VERSION}",
            fix: "Run #{INSTALL_COMMAND}"), report ]
        end

        [ Check.new(name: "sidecar", ok: true, detail: "Browser sidecar #{version}#{" (#{checkout})" if checkout}"), report ]
      end

      def chromium_check(report)
        chromium = report["chromium"].is_a?(Hash) ? report["chromium"] : {}
        return Check.new(name: "chromium", ok: true, detail: "Chromium at #{chromium["executable"]}") if chromium["installed"]

        Check.new(name: "chromium", ok: false, detail: "Chromium is not installed (#{browsers_path})", fix: "Run #{INSTALL_COMMAND}")
      end

      def parse_report(output)
        report = JSON.parse(output.to_s.lines.last.to_s)
        report.is_a?(Hash) ? report : nil
      rescue JSON::ParserError
        nil
      end

      def process_environment
        LocalSandboxBackend.sanitized_environment.merge(environment)
      end

      # Runs +argv+ with output captured, for at most CHECK_TIMEOUT seconds.
      # Returns the output and the exit status, nil when it could not run.
      def capture(argv)
        Open3.popen2e(process_environment, *argv, unsetenv_others: true, pgroup: true) do |stdin, output, waiter|
          stdin.close
          reader = Thread.new { output.read }
          unless waiter.join(CHECK_TIMEOUT)
            Process.kill("KILL", -waiter.pid)
            return [ "timed out after #{CHECK_TIMEOUT}s", nil ]
          end
          [ reader.value, waiter.value ]
        end
      rescue SystemCallError => e
        [ e.message, nil ]
      end

      def run!(io, argv, chdir:)
        io.puts("$ #{argv.join(' ')}")
        Open3.popen2e(process_environment, *argv, chdir: chdir.to_s, unsetenv_others: true, pgroup: true) do |stdin, output, waiter|
          stdin.close
          reader = Thread.new { output.each_line { |line| io.write(line) } }
          unless waiter.join(INSTALL_TIMEOUT)
            Process.kill("KILL", -waiter.pid)
            raise Error, "#{argv.first} did not finish within #{INSTALL_TIMEOUT}s"
          end
          reader.join
          raise Error, "#{argv.join(' ')} failed (#{waiter.value.exitstatus || waiter.value.termsig})" unless waiter.value.success?
        end
      rescue SystemCallError => e
        raise Error, "Could not run #{argv.first}: #{e.message}"
      end
    end
  end
end
