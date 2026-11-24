# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping OpenRouter site URL tests"
  return
end

require_relative "../../../lib/active_agent/providers/open_router_provider"

module Providers
  module OpenRouter
    class SiteUrlTest < ActiveSupport::TestCase
      # Stands in for Rails.application: the options read its class name,
      # its routes and its configuration.
      Application = Struct.new(:routes, :config)
      Routes = Struct.new(:default_url_options)

      # A Rails app generated with --skip-action-mailer: its configuration has
      # no action_mailer to ask.
      test "an app without Action Mailer falls back to the default site URL instead of raising" do
        application = Application.new(Routes.new({}), Object.new)

        Rails.stub(:application, application) do
          options = assert_nothing_raised { ActiveAgent::Providers::OpenRouter::Options.new(api_key: "sk-or-test") }

          assert_predicate options.site_url, :present?
        end
      end

      test "the mailer's default_url_options still name the site when the routes name none" do
        mailer = Struct.new(:default_url_options).new({ host: "tracker.example", protocol: "https" })
        application = Application.new(Routes.new({}), Struct.new(:action_mailer).new(mailer))

        Rails.stub(:application, application) do
          assert_equal "https://tracker.example", ActiveAgent::Providers::OpenRouter::Options.new(api_key: "sk-or-test").site_url
        end
      end
    end
  end
end
