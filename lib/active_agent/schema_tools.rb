# frozen_string_literal: true

require "active_agent/schema_generator"

module ActiveAgent
  # Generates a bounded, enumerable set of read-only tools from an
  # ActiveRecord model.
  #
  # An agent given only generic tools (fetch_url, web_search, calculate) has
  # nothing to call when asked a question about the host application's own
  # data, so it answers from the prompt and invents the rest. SchemaTools
  # closes that gap: a host declares which columns of a model an agent may
  # filter on and which it may read back, and gets a fixed roster of
  # function-calling tools it can hand to a provider.
  #
  # @example Declaring a tool set
  #   class TicketTools < ActiveAgent::SchemaTools
  #     model Ticket
  #     filterable :client, :assignee, :status
  #     returns :id, :subject, :status, :due_date
  #     scope { |actor| TicketPolicy::Scope.new(actor, Ticket).resolve }
  #   end
  #
  #   TicketTools.tool_definitions.map { |d| d[:name] }
  #   # => ["find_tickets", "count_tickets", "get_ticket"]
  #
  #   TicketTools.call("find_tickets", actor: current_user, status: "open")
  #   # => { results: [{ id: 1, subject: "...", ... }], count: 1, truncated: false }
  #
  # = Design properties
  #
  # * **Allowlist-gated.** Only columns passed to {.filterable} may appear in a
  #   filter and only columns passed to {.returns} are ever read back. An
  #   undeclared column is *rejected*, not dropped — silently ignoring an
  #   unknown filter would answer a narrower question than the model asked
  #   while looking like a success, which is how a model ends up confidently
  #   reporting the unfiltered set. Rejecting is also what keeps the boundary
  #   real: without it a model could filter on +users.password_digest+ one
  #   character at a time and read a secret out of the row counts.
  #
  # * **Fixed roster, generated at boot.** Tools are built with +define_method+
  #   at declaration time rather than resolved through +method_missing+,
  #   because every consumer needs to *enumerate* the roster before any call
  #   happens: the dashboard lists available tools, MCP +tools/list+ must
  #   answer without being told a name first, and evals assert on an expected
  #   +tools:+ set. A +method_missing+ design can answer "do you respond to
  #   this?" but cannot answer "what is there?".
  #
  # * **Bounded results.** A +find_*+ with no filters would otherwise select
  #   the whole table into a prompt. Every query is capped and says so via a
  #   +truncated+ flag, so the model can tell "these are all of them" from
  #   "these are the first #{DEFAULT_LIMIT}".
  #
  # * **Authorization is the host's seam, not ours.** {.scope} takes a block
  #   receiving the caller's actor and returning a relation; the generated
  #   tools query through it. SchemaTools does not know what an actor is and
  #   deliberately does not try to authorize — hosts have Pundit, CanCan, or
  #   nothing, and a framework guess would be either wrong or in the way.
  #   Omitting +scope+ runs unscoped, which is a legitimate choice for a
  #   single-tenant or already-trusted context.
  class SchemaTools
    # Default number of rows a find_* tool returns when the caller does not
    # ask for a specific limit.
    DEFAULT_LIMIT = 25

    # Ceiling on rows a single find_* call may return, regardless of what the
    # model passes as +limit+. A model that wants "all of them" will happily
    # ask for 10_000; this is what stops that from becoming the prompt.
    MAX_LIMIT = 100

    # Raised when a tool call names a column outside the declared allowlists,
    # or is otherwise outside the declared boundary.
    class UnpermittedAttribute < ArgumentError; end

    # Raised when a class declares tools without first declaring a model.
    class MissingModel < StandardError; end

    class << self
      # Declares (or reads) the ActiveRecord class these tools expose.
      #
      # Calling this with a model is what triggers tool generation, so it must
      # come before {.filterable} / {.returns} in the class body.
      #
      # @param klass [Class, nil] an ActiveRecord class, or nil to read
      # @return [Class] the declared model
      def model(klass = nil)
        return @model if klass.nil?

        unless defined?(ActiveRecord::Base) && klass < ActiveRecord::Base
          raise ArgumentError, "#{klass} is not an ActiveRecord class"
        end

        @model = klass
        define_tools!
        @model
      end

      # Declares the only columns that may be used as filters.
      #
      # Association names are accepted and resolved to their foreign key, so a
      # host can write +filterable :client+ rather than leaking +client_id+
      # into the tool signature the model sees.
      #
      # @param names [Array<Symbol, String>] column or belongs_to association names
      # @return [Array<Symbol>] the resolved filterable column names
      def filterable(*names)
        return @filterable || [] if names.empty?

        @filterable = names.flatten.map { |name| resolve_column!(name) }
        define_tools!
        @filterable
      end

      # Declares the only columns that may be read back.
      #
      # @param names [Array<Symbol, String>] column names
      # @return [Array<Symbol>] the declared return columns
      def returns(*names)
        return @returns || [] if names.empty?

        @returns = names.flatten.map { |name| resolve_column!(name) }
        define_tools!
        @returns
      end

      # Registers the host's authorization seam.
      #
      # The block receives the actor passed to {.call} and must return an
      # ActiveRecord relation. It is called on every tool invocation rather
      # than memoized, because the relation depends on the actor and a cached
      # one would serve the first caller's rows to the second.
      #
      # @yieldparam actor [Object] whatever the host passes as +actor:+
      # @yieldreturn [ActiveRecord::Relation]
      # @return [Proc, nil]
      # Scopes reads through the host's policy for this model, found by name:
      # Reservation -> ReservationPolicy::Scope, called as
      # `Scope.new(actor, model).resolve`.
      #
      #   class ReservationTools < ActiveAgent::SchemaTools
      #     model Reservation
      #     scope_by_policy
      #   end
      #
      # Opt-in rather than automatic: silently scoping a class that declared no
      # scope would change what an existing tool returns, and a host may run
      # its authorization somewhere other than a Pundit-shaped policy.
      #
      # Raises if the policy cannot be found, so a typo or a missing policy
      # fails at declaration rather than quietly reading the whole table.
      def scope_by_policy(policy = nil, method: :resolve)
        raise MissingModel, "Declare `model` before `scope_by_policy`." unless @model

        resolved = policy || "#{@model.name}Policy::Scope".safe_constantize
        if resolved.nil?
          raise ArgumentError,
            "No policy found for #{@model.name}. Expected #{@model.name}Policy::Scope, " \
            "or pass one: `scope_by_policy MyScope`."
        end

        model_class = @model
        scope { |actor| resolved.new(actor, model_class).public_send(method) }
      end

      def scope(&block)
        return @scope unless block

        @scope = block
      end

      # The full, fixed tool roster in provider function-calling format.
      #
      # @return [Array<Hash>] tool definitions with :name, :description, :parameters
      def tool_definitions
        (@tool_definitions || {}).values.map(&:deep_dup)
      end

      # @return [Array<String>] the names of every generated tool
      def tool_names
        (@tool_definitions || {}).keys
      end

      # @param name [String, Symbol]
      # @return [Boolean] whether this class generated a tool by that name
      def tool?(name)
        (@tool_definitions || {}).key?(name.to_s)
      end

      # Invokes a generated tool by name.
      #
      # Mirrors the dashboard toolbox contract: boundary violations come back
      # as +{ error: ... }+ rather than raising, so a model that guesses a
      # column name gets a correction it can act on instead of killing the
      # run. Genuine programming errors are left to raise.
      #
      # @param name [String, Symbol] the tool name
      # @param actor [Object, nil] passed through to the {.scope} block
      # @param arguments [Hash] tool arguments
      # @return [Hash] the tool result, or +{ error: String }+
      def call(name, actor: nil, **arguments)
        return { error: "Unknown tool: #{name}" } unless tool?(name)

        public_send(name, actor: actor, **arguments)
      rescue UnpermittedAttribute, MissingModel => e
        { error: e.message }
      rescue ArgumentError => e
        { error: "Invalid arguments for #{name}: #{e.message}" }
      end

      # Subclasses get their own declarations rather than sharing the
      # parent's — a roster inherited by reference would let one tool class's
      # allowlist silently widen another's.
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@model, @model)
        subclass.instance_variable_set(:@filterable, (@filterable || []).dup)
        subclass.instance_variable_set(:@returns, (@returns || []).dup)
        subclass.instance_variable_set(:@scope, @scope)
        subclass.instance_variable_set(:@tool_definitions, (@tool_definitions || {}).deep_dup)
      end

      # Resolves the relation a tool queries through.
      #
      # @api private
      def relation_for(actor)
        raise MissingModel, "No model declared. Call `model MyModel` first." unless @model

        return @model.all unless @scope

        relation = @scope.arity.zero? ? @scope.call : @scope.call(actor)
        raise ArgumentError, "scope block must return an ActiveRecord::Relation" unless relation.respond_to?(:where)

        relation
      end

      # Validates and normalizes a filter hash against the allowlist.
      #
      # @api private
      # @raise [UnpermittedAttribute] if any key is not declared filterable
      def permitted_filters!(arguments)
        filters = arguments.each_with_object({}) do |(key, value), memo|
          next if value.nil?

          column = key.to_sym
          unless filterable.include?(column)
            raise UnpermittedAttribute,
              "`#{key}` is not a filterable attribute. Allowed filters: #{filterable.join(", ")}"
          end

          memo[column] = value
        end

        filters
      end

      # Projects a record down to the declared return columns.
      #
      # The projection happens in SQL (+select+) as well as here, but the Ruby
      # side is what actually guarantees the boundary: a +scope+ block that
      # ends in +includes+ or a raw +select+ can hand back a record carrying
      # more columns than were asked for.
      #
      # @api private
      def project(record)
        returns.index_with { |column| serialize_value(record.read_attribute(column)) }
      end

      private

      # Dates and times reach the model as text, not as Ruby objects, so
      # normalize them once here rather than letting each provider's JSON
      # encoder pick its own format.
      def serialize_value(value)
        case value
        when Time, DateTime, ActiveSupport::TimeWithZone then value.iso8601
        when Date then value.to_s
        else value
        end
      end

      # Maps a declared name onto a real column, accepting belongs_to
      # association names as a convenience for their foreign key.
      def resolve_column!(name)
        raise MissingModel, "Declare `model MyModel` before columns" unless @model

        column = name.to_sym
        return column if @model.column_names.include?(column.to_s)

        reflection = @model.reflect_on_association(column)
        if reflection&.belongs_to? && @model.column_names.include?(reflection.foreign_key.to_s)
          return reflection.foreign_key.to_sym
        end

        raise UnpermittedAttribute, "`#{name}` is not a column on #{@model.name}"
      end

      # Builds the fixed tool roster.
      #
      # Re-run after each declaration so the definitions always reflect the
      # current allowlists; the class body calls this two or three times
      # during load and then never again.
      def define_tools!
        return unless @model

        @tool_definitions = {}

        define_find_tool
        define_count_tool
        define_get_tool
      end

      # Parameter schemas come from SchemaGenerator rather than a local type
      # map, so a column's type, format, and enum (from an inclusion
      # validator) are described the same way they are everywhere else in the
      # framework.
      def filter_properties
        return {} if filterable.empty?

        schema = ActiveAgent::SchemaGenerator::Builder.json_schema_from_model(
          @model, include_id: true
        )
        properties = schema[:schema][:properties]

        filterable.index_with { |column| (properties[column] || { type: "string" }).deep_dup }
      end

      def resource_name
        @model.name.underscore
      end

      def collection_name
        resource_name.pluralize
      end

      def define_find_tool
        name = "find_#{collection_name}"
        filters = filter_properties

        register_tool(
          name,
          description: "Find #{collection_name.humanize.downcase} matching the given filters. " \
                       "Returns at most #{MAX_LIMIT} records with these fields: #{returns.join(", ")}.",
          properties: filters.merge(
            limit: {
              type: "integer",
              description: "Maximum records to return (default #{DEFAULT_LIMIT}, max #{MAX_LIMIT})"
            }
          ),
          required: []
        )

        define_singleton_method(name) do |actor: nil, limit: nil, **arguments|
          filters = permitted_filters!(arguments)
          capped = normalize_limit(limit)

          relation = relation_for(actor).where(filters)
          # One extra row distinguishes "exactly at the limit" from "more than
          # the limit", without a second COUNT query.
          records = relation.limit(capped + 1).to_a
          truncated = records.size > capped

          {
            results: records.first(capped).map { |record| project(record) },
            count: [ records.size, capped ].min,
            truncated: truncated
          }
        end
      end

      def define_count_tool
        name = "count_#{collection_name}"

        register_tool(
          name,
          description: "Count #{collection_name.humanize.downcase} matching the given filters.",
          properties: filter_properties,
          required: []
        )

        define_singleton_method(name) do |actor: nil, **arguments|
          filters = permitted_filters!(arguments)

          { count: relation_for(actor).where(filters).count }
        end
      end

      def define_get_tool
        name = "get_#{resource_name}"

        register_tool(
          name,
          description: "Fetch a single #{resource_name.humanize.downcase} by id. " \
                       "Returns these fields: #{returns.join(", ")}.",
          properties: {
            id: { type: "integer", description: "The record id" }
          },
          required: [ "id" ]
        )

        define_singleton_method(name) do |actor: nil, id: nil|
          return { error: "id is required" } if id.nil?

          # find_by through the scoped relation, not find: a record the actor
          # cannot see must read as "not found", never as a 404-vs-403 signal
          # the model could use to probe for existence.
          record = relation_for(actor).find_by(id: id)
          return { error: "No #{resource_name} found with id #{id}" } unless record

          project(record)
        end
      end

      def register_tool(name, description:, properties:, required:)
        @tool_definitions[name] = {
          name: name,
          description: description,
          parameters: {
            type: "object",
            properties: properties,
            required: required
          }
        }
      end

      # Clamp rather than reject an oversized limit: a model asking for 1000
      # rows wants as many as it can get, and an error would just make it ask
      # again. The truncated flag tells it what actually happened.
      def normalize_limit(limit)
        return DEFAULT_LIMIT if limit.nil?

        value = Integer(limit)
        return DEFAULT_LIMIT if value <= 0

        [ value, MAX_LIMIT ].min
      end
    end
  end
end
