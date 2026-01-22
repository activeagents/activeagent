# frozen_string_literal: true

module ActivePrompt
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
