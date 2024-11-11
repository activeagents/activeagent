module ActiveAgent
  module ActionPrompt
    class Action
      include ActiveModel::API
      attr_reader :name, :params
    end
  end
end
