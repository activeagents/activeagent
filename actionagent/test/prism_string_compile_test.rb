# frozen_string_literal: true

require "test_helper"

# Every Ruby file the gems ship must compile when the source is handed to
# the VM as a string, not only by path. That is how bootsnap 1.24.6+ compiles
# files on Ruby 3.4 and 4.0 (its workaround for Ruby bug #22023 goes through
# `compile_prism` with the file's contents), and Prism miscompiles some
# constructs on that path that it accepts by path — `defined?` inside a
# `while` modifier's condition raised "argument stack underflow" and took the
# whole engine down at boot (actionagent 1.9.4, provider_key.rb).
class PrismStringCompileTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)
  GLOBS = %w[lib/**/*.rb actionagent/lib/**/*.rb actionagent/app/**/*.rb].freeze

  test "every shipped Ruby file compiles from a string" do
    skip "RubyVM::InstructionSequence is not available on this Ruby" unless defined?(RubyVM::InstructionSequence)

    failures = GLOBS.flat_map { |glob| Dir.glob(File.join(ROOT, glob)) }.filter_map do |path|
      RubyVM::InstructionSequence.compile(File.read(path, encoding: Encoding::UTF_8), path, path)
      nil
    rescue SyntaxError => error
      "#{path.delete_prefix("#{ROOT}/")}: #{error.message.lines.first.strip}"
    end

    assert_empty failures, "files that do not compile from a string:\n#{failures.join("\n")}"
  end
end
