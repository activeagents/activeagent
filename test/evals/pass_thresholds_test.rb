# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsPassThresholdsTest < ActiveSupport::TestCase
  PassThresholds = ActiveAgent::Evals::PassThresholds

  BASE = {
    "suite" => "support_desk",
    "pass" => { "threshold" => 0.8, "min_pass_rate" => 0.9 },
    "groups" => [
      { "key" => "orders", "name" => "Order support", "pass" => { "min_pass_rate" => 1.0 }, "scenarios" => [] },
      { "key" => "help", "name" => "Product help", "scenarios" => [] },
      { "key" => "experimental", "name" => "Experimental", "pass" => { "gated" => false }, "scenarios" => [] }
    ]
  }.freeze

  OVERLAY = {
    "pass" => { "min_pass_rate" => 0.6 },
    "groups" => [
      { "key" => "orders", "pass" => { "gated" => false } },
      { "key" => "help", "pass" => { "min_pass_rate" => 0.5 } }
    ]
  }.freeze

  def test_the_defaults_pass_everything_that_passes_the_framework_threshold
    thresholds = PassThresholds.default

    assert_equal ActiveAgent::Evals::PASS_THRESHOLD, thresholds.threshold
    assert_equal 1.0, thresholds.min_pass_rate
    assert_equal 1.0, thresholds.min_pass_rate("orders")
    assert thresholds.gated?("orders")
    assert thresholds.gated?(nil)
    assert_equal({ "threshold" => 0.7, "min_pass_rate" => 1.0, "groups" => {} }, thresholds.to_h)
    assert_equal PassThresholds.new, thresholds
  end

  def test_documents_layer_key_by_key_at_both_levels_with_the_later_one_winning
    thresholds = PassThresholds.from_documents([ BASE, OVERLAY ])

    assert_equal 0.8, thresholds.threshold, "the overlay set no threshold, so the base's stands"
    assert_equal 0.6, thresholds.min_pass_rate
    assert_equal 1.0, thresholds.min_pass_rate("orders"), "the overlay ungated the group and left its own bar alone"
    assert_not thresholds.gated?("orders")
    assert_equal 0.5, thresholds.min_pass_rate("help")
    assert thresholds.gated?("help")
    assert_equal 0.6, thresholds.min_pass_rate("experimental"), "a group without its own bar follows the suite's"
    assert_not thresholds.gated?("experimental")
    assert_equal({ "orders" => { "min_pass_rate" => 1.0, "gated" => false }, "help" => { "min_pass_rate" => 0.5 },
                   "experimental" => { "gated" => false } }, thresholds.to_h["groups"])
  end

  def test_a_document_without_a_pass_block_changes_nothing
    base = PassThresholds.from_documents([ BASE ])
    layered = PassThresholds.from_documents([ BASE, { "groups" => [ { "key" => "orders", "scenarios" => [ { "key" => "o_1", "prompt" => "Hi" } ] } ] } ])

    assert_equal base, layered
    assert_equal PassThresholds.default, PassThresholds.from_documents([ { "suite" => "support_desk" } ])
    assert_equal PassThresholds.default, PassThresholds.from_documents([])
  end

  def test_symbol_keys_read_as_strings
    thresholds = PassThresholds.new(suite: { threshold: 0.5 }, groups: { orders: { min_pass_rate: 0.75, gated: true } })

    assert_equal 0.5, thresholds.threshold
    assert_equal 0.75, thresholds.min_pass_rate(:orders)
    assert_equal({ "orders" => { "min_pass_rate" => 0.75, "gated" => true } }, thresholds.to_h["groups"])
    assert_equal thresholds, PassThresholds.from_documents([ { pass: { threshold: 0.5 }, groups: [ { key: :orders, pass: { min_pass_rate: 0.75, gated: true } } ] } ])
  end

  def test_an_unknown_key_names_the_key_and_where_it_was_found
    error = assert_raises(ArgumentError) { PassThresholds.new(suite: { "gated" => false }) }
    assert_includes error.message, '"gated"'
    assert_includes error.message, '"pass" of the suite'

    error = assert_raises(ArgumentError) { PassThresholds.from_documents([ { "groups" => [ { "key" => "orders", "pass" => { "threshold" => 0.5 } } ] } ]) }
    assert_includes error.message, '"threshold"'
    assert_includes error.message, '"pass" of group orders'

    error = assert_raises(ArgumentError) { PassThresholds.from_documents([ { "pass" => 0.8 } ]) }
    assert_includes error.message, '"pass" of the suite must be a mapping'
    error = assert_raises(ArgumentError) { PassThresholds.new(suite: 0.8) }
    assert_includes error.message, '"pass" of the suite must be a mapping'
    error = assert_raises(ArgumentError) { PassThresholds.new(groups: { "orders" => [] }) }
    assert_includes error.message, '"pass" of group orders must be a mapping'
    error = assert_raises(ArgumentError) { PassThresholds.from_documents([ { "groups" => [ { "name" => "No key", "pass" => { "gated" => false } } ] } ]) }
    assert_includes error.message, "group without a key"
    error = assert_raises(ArgumentError) { PassThresholds.from_documents([ { "groups" => [ { "name" => "No key", "pass" => [] } ] } ]) }
    assert_includes error.message, "group without a key", "a keyless group's block is refused whatever it holds"
    assert_equal PassThresholds.default, PassThresholds.from_documents([ { "groups" => [ { "name" => "No key", "scenarios" => [] } ] } ])
  end

  def test_bars_are_numbers_from_zero_to_one_and_gated_is_a_boolean
    assert_raises(ArgumentError) { PassThresholds.new(suite: { "threshold" => 1.5 }) }
    assert_raises(ArgumentError) { PassThresholds.new(suite: { "min_pass_rate" => -0.1 }) }
    assert_raises(ArgumentError) { PassThresholds.new(suite: { "threshold" => "0.8" }) }
    assert_raises(ArgumentError) { PassThresholds.new(suite: { "min_pass_rate" => nil }) }
    assert_raises(ArgumentError) { PassThresholds.new(groups: { "orders" => { "min_pass_rate" => true } }) }
    assert_raises(ArgumentError) { PassThresholds.new(groups: { "orders" => { "gated" => "no" } }) }
    assert_raises(ArgumentError) { PassThresholds.new(groups: { "orders" => { "gated" => nil } }) }

    edges = PassThresholds.new(suite: { "threshold" => 1, "min_pass_rate" => 0 })
    assert_equal 1.0, edges.threshold
    assert_equal 0.0, edges.min_pass_rate
    assert_instance_of Float, edges.min_pass_rate

    whole = PassThresholds.new(groups: { "orders" => { "min_pass_rate" => 1 } })
    fraction = PassThresholds.new(groups: { "orders" => { "min_pass_rate" => 1.0 } })
    assert_instance_of Float, whole.to_h.dig("groups", "orders", "min_pass_rate"), "a whole-number bar reads as a Float"
    assert_equal fraction.to_h.to_json, whole.to_h.to_json
    assert_equal fraction.hash, whole.hash
    assert_equal 1, [ whole, fraction ].uniq.size
  end

  def test_a_groups_bar_falls_back_to_the_suites_and_then_to_the_default
    assert_equal 1.0, PassThresholds.new.min_pass_rate("orders")
    assert_equal 0.9, PassThresholds.new(suite: { "min_pass_rate" => 0.9 }).min_pass_rate("orders")
    assert_equal 0.5, PassThresholds.new(suite: { "min_pass_rate" => 0.9 }, groups: { "orders" => { "min_pass_rate" => 0.5 } }).min_pass_rate("orders")
    assert_equal 0.9, PassThresholds.new(suite: { "min_pass_rate" => 0.9 }, groups: { "orders" => { "gated" => false } }).min_pass_rate("orders")
    assert_equal 0.9, PassThresholds.new(suite: { "min_pass_rate" => 0.9 }, groups: { "orders" => { "min_pass_rate" => 0.5 } }).min_pass_rate(nil)
  end

  def test_only_a_group_that_said_so_is_ungated
    thresholds = PassThresholds.new(groups: { "experimental" => { "gated" => false }, "orders" => { "gated" => true }, "help" => { "min_pass_rate" => 0.5 } })

    assert_not thresholds.gated?("experimental")
    assert_not thresholds.gated?(:experimental)
    assert thresholds.gated?("orders")
    assert thresholds.gated?("help")
    assert thresholds.gated?("unknown")
    assert thresholds.gated?(nil)
  end

  def test_to_h_carries_the_bars_in_effect_and_only_the_keys_each_group_declared
    thresholds = PassThresholds.new(suite: { "min_pass_rate" => 0.8 }, groups: { "orders" => { "min_pass_rate" => 1.0 }, "help" => {} })

    assert_equal({ "threshold" => 0.7, "min_pass_rate" => 0.8, "groups" => { "orders" => { "min_pass_rate" => 1.0 } } }, thresholds.to_h)
    assert_equal thresholds.to_h, JSON.parse(thresholds.to_h.to_json), "the hash is plain JSON"
  end

  def test_two_suites_with_the_same_bars_compare_equal
    a = PassThresholds.from_documents([ BASE, OVERLAY ])
    b = PassThresholds.new(suite: { threshold: 0.8, min_pass_rate: 0.6 },
                           groups: { orders: { min_pass_rate: 1.0, gated: false }, help: { min_pass_rate: 0.5 }, experimental: { gated: false } })

    assert_equal a, b
    assert a.eql?(b)
    assert_equal a.hash, b.hash
    assert_equal 1, [ a, b ].uniq.size
    assert_not_equal a, PassThresholds.from_documents([ BASE ])
    assert_not_equal a, a.to_h
  end
end
