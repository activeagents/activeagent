require "test_helper"
require "generators/active_agent/agent/agent_generator"
require "generators/test_unit/agent_generator"
require "generators/erb/agent_generator"
require "open3"
require "tmpdir"

class RailsAgentPreviewIntegrationTest < ActiveSupport::TestCase
  test "generated previews can be listed rendered downloaded and reloaded" do
    assert_preview_host(enabled: true)
  end

  test "disabled previews have no routes" do
    assert_preview_host(enabled: false)
  end

  test "production does not expose previews by default" do
    assert_preview_host(enabled: nil, environment: "production")
  end

  private

  def assert_preview_host(enabled:, environment: "development")
    Dir.mktmpdir("agent-preview-host") do |root|
      FileUtils.mkdir_p("#{root}/app/agents")
      FileUtils.mkdir_p("#{root}/config")
      File.write("#{root}/app/agents/application_agent.rb", <<~RUBY)
        class ApplicationAgent < ActiveAgent::Base
          generate_with :mock
        end
      RUBY
      %w[preview_sample admin/preview_sample].each do |name|
        ActiveAgent::Generators::AgentGenerator.start(
          [ name, "greet", "--test-framework=test_unit", "--quiet" ], destination_root: root
        )
      end
      FileUtils.mkdir_p("#{root}/test/docs/previews")
      File.write("#{root}/test/docs/previews/legacy_preview.rb", "class LegacyPreview < ActiveAgent::Preview; end")
      FileUtils.mkdir_p("#{root}/custom_previews")
      File.write("#{root}/custom_previews/custom_preview.rb", "class CustomPreview < ActiveAgent::Preview; end")
      File.write("#{root}/config/routes.rb", "Rails.application.routes.draw {}")
      File.write("#{root}/check.rb", host_script(enabled:, environment:))
      output, status = Open3.capture2e(RbConfig.ruby, "check.rb", chdir: root)
      assert status.success?, output
      assert_includes output, "preview host verified"
    end
  end

  def host_script(enabled:, environment:)
    <<~RUBY
      ENV["RAILS_ENV"] = #{environment.inspect}
      require "rails"
      require "active_model/railtie"
      require "active_job/railtie"
      require "action_controller/railtie"
      require "active_agent"
      require "webmock"
      WebMock.disable_net_connect!
      class PreviewHost < Rails::Application
        config.root = __dir__
        config.eager_load = false
        config.cache_classes = false
        config.secret_key_base = "synthetic-test-secret"
        config.logger = Logger.new(File::NULL)
        config.hosts.clear
        config.consider_all_requests_local = false
        config.action_dispatch.show_exceptions = :none
        config.active_agent.show_previews = #{enabled.inspect}
        config.active_agent.preview_paths << File.join(__dir__, "custom_previews")
      end
      PreviewHost.initialize!
      require "active_agent/providers/mock_provider"
      ActiveAgent::Providers::MockProvider.prepend(Module.new do
        def api_prompt_execute(*)
          raise "previews must not execute a provider request"
        end
      end)
      require "action_dispatch/testing/integration"
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.remote_addr = "127.0.0.1"
      if #{!!enabled}
        session.get "/rails/agents"
        raise "index failed: \#{session.response.status}" unless session.response.status == 200
        %w[preview_sample_agent admin/preview_sample_agent legacy custom].each do |name|
          raise "missing \#{name}" unless session.response.body.include?(name)
        end
        session.get "/rails/agents/admin/preview_sample_agent"
        raise "namespaced list failed" unless session.response.status == 200
        session.get "/rails/agents/admin/preview_sample_agent/greet", params: { message: "<script>synthetic</script>", host: "example.invalid", script_name: "//example.invalid" }
        raise "preview failed: \#{session.response.status}" unless session.response.status == 200
        raise "unsafe download link" unless session.response.body.include?('href="/rails/agents/download/admin/preview_sample_agent/greet?')
        raise "unescaped content" unless session.response.body.include?("&lt;script&gt;synthetic&lt;/script&gt;")
        session.get "/rails/agents/download/preview_sample_agent/greet", params: { message: "synthetic download" }
        raise "download failed" unless session.response.status == 200 && session.response.body.include?("synthetic download")
        raise "wrong download type" unless session.response.media_type == "text/markdown"
        raise "not an attachment" unless session.response.headers["Content-Disposition"].include?("attachment")
        %w[missing/greet preview_sample_agent/missing preview_sample_agent/object_id].each do |path|
          session.get "/rails/agents/\#{path}"
          raise "unknown path accepted" unless session.response.status == 404
        end
        file = File.join(__dir__, "test/agents/previews/preview_sample_agent_preview.rb")
        File.write(file, File.read(file).sub("def greet", "def changed"))
        Rails.application.reloader.reload!
        session.get "/rails/agents/preview_sample_agent"
        raise "reload failed" unless session.response.status == 200 && session.response.body.include?("changed")
        session.get "/rails/agents/preview_sample_agent/changed"
        raise "reloaded prompt failed" unless session.response.status == 200
        session.remote_addr = "203.0.113.7"
        [ "/rails/agents", "/rails/agents/preview_sample_agent/changed", "/rails/agents/download/preview_sample_agent/changed" ].each do |path|
          session.get path
          raise "remote preview accepted" unless session.response.status == 403
        end
      else
        raise "preview route exists" if Rails.application.routes.routes.any? { |route| route.defaults[:controller] == "rails/agents" }
      end
      puts "preview host verified"
    RUBY
  end
end
