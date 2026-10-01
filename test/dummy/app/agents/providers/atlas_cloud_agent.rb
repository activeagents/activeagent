# frozen_string_literal: true

module Providers
  # region agent
  class AtlasCloudAgent < ApplicationAgent
    generate_with :atlas_cloud, model: "qwen/qwen3.8-max"

    def ask
      prompt(message: params[:message])
    end
  end
  # endregion agent
end
