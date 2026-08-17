# frozen_string_literal: true

require "test_helper"

# Base class for the cross-repo integration suite: activeagent and
# solid_agent exercised together, in the dummy Rails app, against the
# generated host-app models.
#
# The two gems release independently, so the version of solid_agent in the
# bundle is not always the one this repository is developing against. Rather
# than pin it — which would hide the released combination — a test declares
# what it needs and skips when the resolved gem cannot do it:
#
#   requires_solid_agent "SolidAgent::HasMemory"
#
# SOLID_AGENT_STRICT=1 turns those skips into failures. CI runs the suite
# twice: once against the released gem (skips allowed, so drift is visible
# in the log) and once against solid_agent main with strict on, which is
# what asserts the source-to-source combination actually works.
class SolidAgentIntegrationTest < ActiveSupport::TestCase
  STRICT = ENV["SOLID_AGENT_STRICT"].present?

  class << self
    def requires_solid_agent(*constants)
      @required_constants = Array(@required_constants) + constants.flatten.map(&:to_s)
    end

    def required_constants
      Array(@required_constants) + (superclass.respond_to?(:required_constants) ? superclass.required_constants : [])
    end

    # For API shape rather than existence — a keyword that was renamed, a
    # method that grew an argument. The block runs at test time, so it can
    # reflect on whatever version resolved.
    def requires_solid_agent_capability(description, &predicate)
      @required_capabilities = Array(@required_capabilities) + [ [ description, predicate ] ]
    end

    def required_capabilities
      Array(@required_capabilities) +
        (superclass.respond_to?(:required_capabilities) ? superclass.required_capabilities : [])
    end
  end

  requires_solid_agent "SolidAgent::HasContext"

  setup do
    unmet = self.class.required_constants.reject { |name| self.class.solid_agent_const_defined?(name) }
    unmet += self.class.required_capabilities.reject { |_, predicate| predicate.call }.map(&:first)

    if unmet.any?
      message = "solid_agent #{SolidAgentIntegrationTest.installed_version} does not provide " \
        "#{unmet.join(', ')} — run with gemfiles/solid_agent_main.gemfile to cover it"

      # Printed rather than left to the reporter, which only shows skip
      # reasons in verbose mode. On the released combination this list is
      # the report: it names every API the published gem is missing.
      puts "[solid_agent] SKIP #{self.class.name}##{name}: #{message}"

      STRICT ? flunk(message) : skip(message)
    end

    AgentMemoryEntry.delete_all
    AgentMemory.delete_all
    AgentMessage.delete_all
    AgentGeneration.delete_all
    AgentContext.delete_all
    AgentRun.delete_all
  end

  def self.solid_agent_const_defined?(name)
    name.to_s.split("::").inject(Object) do |namespace, part|
      return false unless namespace.const_defined?(part, false)

      namespace.const_get(part, false)
    end

    true
  rescue NameError
    false
  end

  def self.installed_version
    Gem.loaded_specs["solid_agent"]&.version&.to_s || "(not resolved)"
  end

  # The dummy app's user, as a stand-in for whatever record a host app hangs
  # conversations and memory off.
  def subject_record
    @subject_record ||= User.create!(
      name: "Integration Subject",
      email: "integration-#{SecureRandom.hex(4)}@example.com",
      age: 30,
      role: "user"
    )
  end
end
