# frozen_string_literal: true

require "fileutils"
require "yaml"

module ActiveAgent
  class CLI
    # Named dashboard profiles in ~/.config/activeagent/credentials.yml
    # ($XDG_CONFIG_HOME when set), written 0600 inside a 0700 directory:
    #
    #   default:
    #     url: https://ops.example.com/activeagents
    #     api_key: aa_...
    #     ingest_key: ...   # only when it differs from api_key
    #
    # A profile's values are what +login+ stored; the environment
    # (ACTIVEAGENT_URL, ACTIVEAGENT_API_KEY, ACTIVEAGENT_INGEST_KEY) overrides
    # them in CLI#profile, so CI never needs the file.
    class Credentials
      FIELDS = %w[url api_key ingest_key].freeze

      attr_reader :path

      def self.default_path(env = ENV)
        base = env["XDG_CONFIG_HOME"].to_s.empty? ? File.join(Dir.home, ".config") : env["XDG_CONFIG_HOME"]
        File.join(base, "activeagent", "credentials.yml")
      end

      def initialize(path)
        @path = path
      end

      # Returns the profile's stored values, or an empty hash when the file or
      # the profile does not exist.
      def [](name)
        profiles.fetch(name.to_s, {})
      end

      def names
        profiles.keys
      end

      def save(name, values)
        data = profiles.merge(name.to_s => values.transform_keys(&:to_s).slice(*FIELDS).compact)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        # Written beside the target and renamed over it, so a reader never
        # sees half a file, and created 0600 so the key is never readable by
        # others, even for a moment.
        temp = "#{path}.#{Process.pid}.tmp"
        File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(YAML.dump(data)) }
        File.chmod(0o600, temp)
        File.rename(temp, path)
      ensure
        FileUtils.rm_f(temp) if temp && File.exist?(temp)
      end

      def delete(name)
        data = profiles
        return false unless data.delete(name.to_s)

        data.empty? ? File.delete(path) : File.open(path, "w", 0o600) { |file| file.write(YAML.dump(data)) }
        true
      end

      private

      def profiles
        return {} unless File.exist?(path)

        data = YAML.safe_load_file(path) || {}
        raise Error.new("#{path} is not a profile map; fix or remove it", exit_code: EXIT_CONFIG) unless data.is_a?(Hash)

        data.select { |_, values| values.is_a?(Hash) }
      rescue Psych::Exception => e
        raise Error.new("#{path} is not valid YAML (#{e.class}); fix or remove it", exit_code: EXIT_CONFIG)
      end
    end
  end
end
