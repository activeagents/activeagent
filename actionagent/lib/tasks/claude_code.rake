# frozen_string_literal: true

namespace :action_agent do
  namespace :claude_code do
    # Earlier versions accepted a `claude setup-token` token (a Claude
    # subscription credential) for the Claude Code connection. Anthropic does
    # not let third-party products store those, and they are no longer used;
    # this removes the ones still stored. Run it once after upgrading.
    desc "Delete stored Claude Code connections holding a Claude subscription token (sk-ant-oat…), " \
         "which are no longer used; their owners connect an Anthropic API key instead"
    task purge_subscription_tokens: :environment do
      count = ActionAgent::ProviderKey.purge_subscription_tokens!
      puts "Deleted #{count} stored Claude subscription token(s)"
    end
  end
end
