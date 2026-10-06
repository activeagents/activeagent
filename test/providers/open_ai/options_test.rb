# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping OpenAI options tests"
  return
end

require_relative "../../../lib/active_agent/providers/open_ai_provider"

module Providers
  module OpenAI
    class OptionsTest < ActiveSupport::TestCase
      PROJECT_ENV = %w[OPENAI_PROJECT_ID OPEN_AI_PROJECT_ID].freeze

      test "prefers an explicit api_key over OPENAI_API_KEY" do
        with_env("OPENAI_API_KEY" => "sk-env") do
          options = ActiveAgent::Providers::OpenAI::Options.new(api_key: "sk-explicit")

          assert_equal "sk-explicit", options.api_key
        end
      end

      test "keeps an explicit project_id when no environment project is set" do
        with_env(PROJECT_ENV.to_h { |name| [ name, nil ] }) do
          options = ActiveAgent::Providers::OpenAI::Options.new(api_key: "sk-explicit", project_id: "proj_explicit")

          assert_equal "proj_explicit", options.project
        end
      end

      test "prefers an explicit project over OPENAI_PROJECT_ID" do
        with_env("OPENAI_PROJECT_ID" => "proj_env", "OPEN_AI_PROJECT_ID" => nil) do
          options = ActiveAgent::Providers::OpenAI::Options.new(api_key: "sk-explicit", project: "proj_explicit")

          assert_equal "proj_explicit", options.project
        end
      end

      test "prefers an explicit project_id over OPENAI_PROJECT_ID" do
        with_env("OPENAI_PROJECT_ID" => "proj_env", "OPEN_AI_PROJECT_ID" => nil) do
          options = ActiveAgent::Providers::OpenAI::Options.new(api_key: "sk-explicit", project_id: "proj_explicit")

          assert_equal "proj_explicit", options.project
        end
      end

      test "falls back to OPENAI_PROJECT_ID" do
        with_env("OPENAI_PROJECT_ID" => "proj_env", "OPEN_AI_PROJECT_ID" => nil) do
          options = ActiveAgent::Providers::OpenAI::Options.new(api_key: "sk-explicit")

          assert_equal "proj_env", options.project
        end
      end

      private

      # Sets each variable for the block (nil unsets it) and restores the
      # original environment afterwards.
      def with_env(values)
        previous = values.keys.to_h { |name| [ name, ENV[name] ] }
        values.each { |name, value| ENV[name] = value }
        yield
      ensure
        previous.each { |name, value| ENV[name] = value }
      end
    end
  end
end
