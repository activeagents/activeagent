# frozen_string_literal: true

class DelayedAgentError < StandardError; end

class DelayedAgent < ActiveAgent::Base
  self.generate_later_queue_name = :delayed_agents

  cattr_accessor :last_error
  cattr_accessor :last_rescue_from_instance

  rescue_from DelayedAgentError do |error|
    @@last_error = error
    @@last_rescue_from_instance = self
  end

  rescue_from ActiveJob::DeserializationError do |error|
    @@last_error = error
    @@last_rescue_from_instance = self
  end

  def test_message(*)
    prompt(from: "test-sender@test.com", to: "test-receiver@test.com", subject: "Test Subject", body: "Test Body")
  end

  def test_kwargs(argument:)
    prompt(from: "test-sender@test.com", to: "test-receiver@test.com", subject: "Test Subject", body: "Test Body")
  end

  def test_raise(klass_name)
    raise klass_name.constantize, "boom"
  end
end
