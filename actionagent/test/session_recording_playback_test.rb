# frozen_string_literal: true

require "test_helper"

# What Session Replay reads to play a recording back: the show timeline and
# the paged action list.
class SessionRecordingPlaybackTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::RecordingAction.delete_all
    ActionAgent::SessionRecording.delete_all

    @recording = ActionAgent::SessionRecording.start_user_session!(page_url: "https://example.com/")
    %w[navigate click type].each do |action_type|
      @recording.record_action!(action_type: action_type, selector: "#query", value: "shoes")
    end
  end

  def actions_page(**params)
    get "/activeagents/api/session_recordings/#{@recording.id}/actions", params: params
    assert_response :success
    JSON.parse(response.body)
  end

  def sequences(page)
    page["actions"].map { |action| action["sequence"] }
  end

  test "show timeline entries name the action as the action list does" do
    get "/activeagents/api/session_recordings/#{@recording.id}"

    assert_response :success
    timeline = JSON.parse(response.body).dig("recording", "timeline")
    assert_equal %w[navigate click type], timeline.map { |entry| entry["action_type"] }
    assert_equal %w[navigate click type], timeline.map { |entry| entry["type"] }
  end

  test "after_sequence pages through the actions" do
    first = actions_page(limit: 2)
    assert_equal [ 1, 2 ], sequences(first)
    assert first["has_more"]
    assert_equal 3, first["total_actions"]

    rest = actions_page(limit: 2, after_sequence: sequences(first).last)
    assert_equal [ 3 ], sequences(rest)
    assert_not rest["has_more"]
  end

  test "a page that ends at the last action reports no more" do
    page = actions_page(limit: 3)

    assert_equal [ 1, 2, 3 ], sequences(page)
    assert_not page["has_more"]
  end

  test "the limit is clamped to at least one action" do
    page = actions_page(limit: 0)

    assert_equal [ 1 ], sequences(page)
    assert page["has_more"]
  end
end
