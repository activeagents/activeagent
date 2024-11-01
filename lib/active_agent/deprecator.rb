# frozen_string_literal: true

module ActiveAgent
  def self.deprecator # :nodoc:
    @deprecator ||= ActiveSupport::Deprecation.new
  end
end
