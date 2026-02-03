# frozen_string_literal: true
class ApplicationAgent < ApplicationRecord
  include ActiveAgent::HasContext
  has_context prompts: :prompts, messages: :messages, tools: :actions

  validates :name, presence: true
end
