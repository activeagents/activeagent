# frozen_string_literal: true

require "digest"
require "json"

module ActiveAgent
  # A release of an agent is what the model is given: the provider and model,
  # the generation options, the prompt templates on disk, the actions and the
  # tools the class declares. {ClassMethods#release_digest} names that
  # deterministically, so two deploys that ship the same agent share a digest
  # and a change to any of those inputs yields a new one — without anyone
  # bumping a number by hand.
  #
  # The digest is what telemetry stamps on every generation (`agent.version`)
  # and what a dashboard cuts an AgentVersion from on deploy, so a trace, a
  # run and an evaluation can all say which release of the agent produced
  # them. {Release.revision} carries the deploy itself (a git SHA or a release
  # label) alongside, when the host knows it.
  #
  # Class-level and memoized: in development a reload replaces the class, so
  # the next reference recomputes it.
  module Release
    extend ActiveSupport::Concern

    # Option keys that never belong in a manifest: credentials, and per-call
    # state the class does not own.
    EXCLUDED_OPTION_KEYS = %i[
      api_key access_token secret password token trace_id messages message instructions
    ].freeze
    SECRET_KEY_PATTERN = /key|token|secret|password|credential/i

    # How the deploy identifies itself, when it does. A host sets
    # `ActiveAgent::Release.revision = ENV["GIT_SHA"]` (or a proc) from an
    # initializer; otherwise the conventional deploy variables are read.
    class << self
      attr_writer :revision

      # @return [String, nil]
      def revision
        value = @revision.respond_to?(:call) ? @revision.call : @revision
        value = value.presence || ENV.values_at("SERVICE_VERSION", "GIT_SHA", "KAMAL_VERSION", "SOURCE_VERSION", "HEROKU_SLUG_COMMIT").find(&:present?)
        value&.to_s
      end

      # Canonical JSON: sorted keys at every level, so the digest does not
      # depend on the order anything was declared in.
      # @api private
      def canonical(value)
        case value
        when Hash then value.map { |k, v| [ k.to_s, canonical(v) ] }.sort_by(&:first).to_h
        when Array then value.map { |v| canonical(v) }
        when Symbol then value.to_s
        else value
        end
      end
    end

    class_methods do
      # Everything about this class that shapes a generation, as data.
      #
      # @return [Hash]
      def release_manifest
        @release_manifest ||= Release.canonical(
          agent: name,
          provider: release_provider,
          model: prompt_options&.dig(:model),
          options: release_options,
          actions: release_actions,
          templates: release_templates,
          tools: release_tools,
          delegations: release_delegations
        )
      end

      # A short, stable identifier for {#release_manifest}: the first twelve
      # hex characters of its SHA-256.
      #
      # @return [String]
      def release_digest
        @release_digest ||= Digest::SHA256.hexdigest(JSON.generate(release_manifest))[0, 12]
      end

      # Forgets the memoized manifest and digest — for a host that edits
      # templates at runtime, and for tests.
      # @return [void]
      def reset_release!
        @release_manifest = nil
        @release_digest = nil
      end

      private

      def release_provider
        provider = respond_to?(:prompt_provider) ? prompt_provider : nil
        (provider || prompt_options&.dig(:service))&.to_s
      end

      # Generation options minus credentials and per-call state. Nested
      # hashes are walked so a token under `options: { headers: … }` is
      # dropped too.
      def release_options
        strip_secrets((prompt_options || {}).except(*EXCLUDED_OPTION_KEYS, :model, :service))
      end

      def strip_secrets(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, inner), kept|
            next if EXCLUDED_OPTION_KEYS.include?(key.to_sym) || key.to_s.match?(SECRET_KEY_PATTERN)

            kept[key] = strip_secrets(inner)
          end
        when Array then value.map { |inner| strip_secrets(inner) }
        else value
        end
      end

      # The public actions — the prompts a caller can invoke.
      def release_actions
        respond_to?(:action_methods) ? action_methods.to_a.sort : []
      end

      # Every template file under this agent's view prefixes, keyed by its
      # path relative to the view root, with a digest of its contents. The
      # prefixes mirror View#_prefixes without an action: `app/views/<agent>/`
      # and `app/views/agents/<agent without suffix>/`.
      def release_templates
        return {} if anonymous? || !respond_to?(:view_paths)

        base = name.underscore
        prefixes = [ base, "agents/#{base.delete_suffix("_agent")}" ]
        roots = Array(view_paths).map { |path| path.respond_to?(:to_path) ? path.to_path : path.to_s }

        roots.each_with_object({}) do |root, templates|
          prefixes.each do |prefix|
            Dir.glob(File.join(root, prefix, "**", "*")).sort.each do |file|
              next unless File.file?(file)

              relative = file.delete_prefix("#{root}/")
              templates[relative] = Digest::SHA256.hexdigest(File.binread(file))[0, 12]
            end
          end
        end
      end

      # Tool definitions the class declares itself (a host convention such as
      # schema-derived rosters), reduced to what identifies them.
      def release_tools
        return [] unless respond_to?(:tool_definitions)

        Array(tool_definitions).map do |definition|
          next definition.to_s unless definition.respond_to?(:to_h)

          hash = definition.to_h
          {
            name: (hash[:name] || hash["name"]).to_s,
            description: (hash[:description] || hash["description"]).to_s,
            parameters: hash[:parameters] || hash["parameters"]
          }
        end.sort_by { |tool| tool.is_a?(Hash) ? tool[:name] : tool }
      end

      # The delegations this class declares, by tool name.
      def release_delegations
        return [] unless respond_to?(:delegations)

        Array(delegations).map { |tool_name, _definition| tool_name.to_s }.sort
      end
    end
  end
end
