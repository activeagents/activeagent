# frozen_string_literal: true

namespace :action_agent do
  namespace :browser do
    desc "Install the browser sidecar and its Chromium for the :local sandbox backend, under the local sandbox root"
    task install: :environment do
      ActionAgent::BrowserSidecar.install!
      puts "Installed the browser sidecar under #{ActionAgent::BrowserSidecar.root}"
    rescue ActionAgent::BrowserSidecar::Error => e
      abort "action_agent:browser:install: #{e.message}"
    end

    desc "Check that a sandbox's browser can start on this machine: Node.js, the browser sidecar and Chromium"
    task doctor: :environment do
      checks = ActionAgent::BrowserSidecar.checks
      checks.each { |check| puts "#{check.ok ? '[ok]     ' : '[missing]'} #{check.name}: #{check.message}" }
      abort "Browser sessions cannot start on this machine yet." unless checks.all?(&:ok)

      puts "Browser sessions can start on this machine."
    end
  end
end
