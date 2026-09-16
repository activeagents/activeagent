# frozen_string_literal: true

require "test_helper"

# The railtie installs generation instrumentation at boot, but it can only
# see configuration that is already loaded by then. A host app that enables
# telemetry from its own `config/initializers/*.rb` runs *after* railties, so
# that check had already seen `enabled? == false` and skipped the install —
# leaving telemetry enabled, a valid local_store, and no traces at all.
#
# Configure is the one funnel every such app goes through, so the install
# happens there too and initializer order stops mattering.
class InstrumentationInstallTest < ActiveSupport::TestCase
  setup do
    @original = ActiveAgent::Telemetry.configuration
    ActiveAgent::Telemetry.reset_configuration!
  end

  teardown do
    ActiveAgent::Telemetry.instance_variable_set(:@configuration, @original)
  end

  def instrumented?
    ActiveAgent::Base.ancestors.any? { |m| m.name.to_s.include?("GenerationInstrumentation") }
  end

  test "enabling telemetry after boot installs instrumentation" do
    ActiveAgent::Telemetry.configure do |config|
      config.enabled = true
      config.local_storage = true
    end

    assert ActiveAgent::Telemetry.enabled?, "precondition: telemetry is enabled"
    assert instrumented?, "enabling telemetry must install generation instrumentation"
  end

  test "repeated configure calls do not prepend instrumentation twice" do
    2.times do
      ActiveAgent::Telemetry.configure do |config|
        config.enabled = true
        config.local_storage = true
      end
    end

    matches = ActiveAgent::Base.ancestors.count { |m| m.name.to_s.include?("GenerationInstrumentation") }
    assert_equal 1, matches, "instrument_telemetry! must stay idempotent across configure calls"
  end

  test "configuring without enabling does not instrument" do
    # Guards the inverse mistake: installing unconditionally would trace for
    # apps that deliberately left telemetry off.
    ActiveAgent::Telemetry.reset_configuration!
    before = instrumented?

    ActiveAgent::Telemetry.configure { |config| config.sample_rate = 0.5 }

    assert_equal before, instrumented?, "a disabled configure must not install instrumentation"
  end
end
