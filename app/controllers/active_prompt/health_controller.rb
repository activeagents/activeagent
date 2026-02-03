# frozen_string_literal: true

module ActivePrompt
  class HealthController < ApplicationController
    def show
      render plain: "ok"
    end
  end
end
