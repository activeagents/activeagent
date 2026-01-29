# frozen_string_literal: true
require "test_helper"

class ActivePromptIndexesTest < ActiveSupport::TestCase
  def test_messages_prompt_position_index_named
    index_names = ActiveRecord::Base.connection.indexes(:active_prompt_messages).map(&:name)
    assert_includes index_names, "idx_ap_messages_prompt_position"
  end

  def test_actions_prompt_name_index_named
    index_names = ActiveRecord::Base.connection.indexes(:active_prompt_actions).map(&:name)
    assert_includes index_names, "idx_ap_actions_prompt_name"
  end
end
