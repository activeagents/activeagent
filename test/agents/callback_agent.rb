# frozen_string_literal: true

require "test_helper"

CallbackAgentError = Class.new(StandardError)
class CallbackAgent < ActiveAgent::Base
  generate_with :test
  cattr_accessor :rescue_from_error
  cattr_accessor :after_generation_instance
  cattr_accessor :around_generation_instance
  cattr_accessor :abort_before_generation
  cattr_accessor :around_handles_error

  rescue_from CallbackAgentError do |error|
    @@rescue_from_error = error
  end

  before_generation do
    throw :abort if @@abort_before_generation
  end

  after_generation do
    @@after_generation_instance = self
  end

  around_generation do |mailer, block|
    @@around_generation_instance = self
    block.call
  rescue
    raise unless @@around_handles_error
  end

  def test_message(*)
    prompt(message: "Test Body")
  end

  def test_raise_action
    raise CallbackAgentError, "agent action processing"
  end
end
