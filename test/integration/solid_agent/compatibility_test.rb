# frozen_string_literal: true

require_relative "integration_case"

# The release-coordination check: can these two versions ship together?
#
# activeagent and solid_agent version independently, and solid_agent depends
# on activeagent — so a framework release can break the gem downstream of it
# without anything in either test suite noticing. These assertions are the
# things that would go wrong silently.
class SolidAgentCompatibilityTest < SolidAgentIntegrationTest
  # Constants this repository dereferences without a `defined?` guard: if
  # one of them goes, a run raises. SolidAgent::ToolCache is deliberately
  # absent from this list — AgentToolbox falls back when it is missing, and
  # tool_cache_test asserts the two paths agree.
  REQUIRED_CONSTANTS = %w[
    SolidAgent::HasContext
  ].freeze

  test "solid_agent is resolved in this bundle" do
    assert Gem.loaded_specs.key?("solid_agent"),
      "solid_agent is not in the bundle — actionagent declares it as a dependency"
  end

  test "the resolved solid_agent accepts this checkout's activeagent version" do
    requirement = Gem.loaded_specs.fetch("solid_agent").dependencies
      .find { |dependency| dependency.name == "activeagent" }&.requirement

    assert requirement, "solid_agent no longer declares a dependency on activeagent"

    assert requirement.satisfied_by?(Gem::Version.new(ActiveAgent::VERSION)),
      "solid_agent #{SolidAgentIntegrationTest.installed_version} requires activeagent " \
      "#{requirement}, which this checkout (#{ActiveAgent::VERSION}) does not satisfy — " \
      "releasing this version of the framework would break solid_agent"
  end

  test "the resolved solid_agent satisfies actionagent's declared dependency" do
    requirement = Gem::Specification.load("actionagent/actionagent.gemspec").dependencies
      .find { |dependency| dependency.name == "solid_agent" }&.requirement

    assert requirement, "actionagent no longer declares a dependency on solid_agent"

    assert requirement.satisfied_by?(Gem.loaded_specs.fetch("solid_agent").version),
      "actionagent requires solid_agent #{requirement}, resolved " \
      "#{SolidAgentIntegrationTest.installed_version}"
  end

  test "every SolidAgent constant this repository names unguarded exists" do
    missing = REQUIRED_CONSTANTS.reject { |name| SolidAgentIntegrationTest.solid_agent_const_defined?(name) }

    assert_empty missing,
      "this repository references #{missing.join(', ')}, absent from solid_agent " \
      "#{SolidAgentIntegrationTest.installed_version}"
  end

  test "has_context still takes the options the dashboard passes it" do
    # ActionAgent::AgentExecutionService builds an agent class and calls
    # has_context with these keywords. A rename upstream surfaces only when
    # a run executes — which is how contextable:/contextual: got missed.
    assert_includes keywords_of(:has_context), :class_name
    assert_includes keywords_of(:has_context), :message_class
    assert_includes keywords_of(:has_context), :generation_class

    assert_includes keywords_of(:has_context), ActionAgent.solid_agent_auto_context_keyword,
      "ActionAgent.solid_agent_auto_context_keyword resolved to a keyword solid_agent " \
      "#{SolidAgentIntegrationTest.installed_version} does not accept"
  end

  test "the dashboard builds a runnable agent class against the resolved gem" do
    agent = ActionAgent::Agent.create!(
      name: "Compatibility", provider: "mock", model: "mock", instructions: "Be brief."
    )
    run = agent.agent_runs.create!(trace_id: SecureRandom.uuid, status: :pending)

    response = ActionAgent::AgentExecutionService.new(agent, run).send(:generate!)

    assert response, "the dashboard's runtime agent class failed to generate"
    assert_operator ActionAgent::AgentContext.count, :>, 0,
      "the run did not persist a conversation through solid_agent"
  end

  private

  def keywords_of(method_name)
    SolidAgent::HasContext::ClassMethods.instance_method(method_name).parameters
      .select { |type, _| [ :key, :keyreq ].include?(type) }
      .map(&:last)
  end
end
