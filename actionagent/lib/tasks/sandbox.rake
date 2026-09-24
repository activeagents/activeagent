# frozen_string_literal: true

namespace :action_agent do
  namespace :sandbox do
    desc "Write this app's checkout sandbox runtime manifest ({mcp_path, mcp_token}) to " \
         "$ACTION_AGENT_SANDBOX_MANIFEST, or print it"
    task manifest: :environment do
      manifest = JSON.generate(ActionAgent::SandboxManifest.generate)

      if (path = ENV[ActionAgent::SandboxManifest::PATH_ENV].presence)
        File.write(path, manifest)
      else
        puts manifest
      end
    rescue ActionAgent::SandboxManifest::Error => e
      abort "action_agent:sandbox:manifest: #{e.message}"
    end

    desc "Expire sandbox sessions past their expiry and release what their backend holds " \
         "(processes, containers). Schedule it, e.g. every few minutes."
    task reap: :environment do
      count = ActionAgent::SandboxCleanupJob.cleanup_expired!
      puts "Expired #{count.to_i} sandbox session(s)"
    end
  end
end
