# frozen_string_literal: true

# A stand-in for Bundler's `bundle`, first on PATH in LocalSandboxBackendTest's
# bootstrap boots. Plain Ruby and the standard library only.
#
# Appends each invocation to $FAKE_TOOLS_LOG, then:
#
#   config set --local frozen false   writes .bundle/config
#   install                           does nothing
#   add NAME [options]                adds NAME, with its options, to the
#                                     Gemfile, and locks it in Gemfile.lock
#
# $FAKE_CONTROL names a JSON file; a command listed under "fail" (by its first
# two words, "bundle install") exits 1.
require "json"

line = [ "bundle", *ARGV ].join(" ")
File.open(ENV.fetch("FAKE_TOOLS_LOG"), "a") { |file| file.puts(line) }
control = ENV["FAKE_CONTROL"] && File.exist?(ENV["FAKE_CONTROL"]) ? JSON.parse(File.read(ENV["FAKE_CONTROL"])) : {}

if Array(control["fail"]).include?(line.split.first(2).join(" "))
  puts "fake bundle: #{line} failed"
  exit 1
end

case ARGV.first
when "config"
  Dir.mkdir(".bundle") unless Dir.exist?(".bundle")
  File.write(".bundle/config", "---\nBUNDLE_FROZEN: \"false\"\n")
when "add"
  name = ARGV[1]
  options = ARGV.drop(2).reject { |arg| arg == "--skip-install" }.each_slice(2).to_h
  declaration = [ "gem #{name.inspect}" ]
  declaration << options["--version"].inspect if options["--version"]
  declaration << "path: #{options["--path"].inspect}" if options["--path"]
  declaration << "git: #{options["--git"].inspect}, ref: #{options["--ref"].inspect}" if options["--git"]
  File.open("Gemfile", "a") { |file| file.puts(declaration.join(", ")) }
  lock = File.read("Gemfile.lock")
  File.write("Gemfile.lock", lock.sub("  specs:\n", "  specs:\n    #{name} (1.9.0)\n"))
  puts "fake bundle: added #{name}"
end
