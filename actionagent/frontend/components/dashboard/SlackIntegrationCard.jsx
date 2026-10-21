import React from 'react';
import CredentialIntegrationCard from './CredentialIntegrationCard';

// The bot token agents with the Slack tool read channels and post with.
export default function SlackIntegrationCard({ onChange }) {
  return (
    <CredentialIntegrationCard
      provider="slack"
      title="Slack"
      description="Agents with the Slack tool list channels, read them and post as this bot. Create a Slack app with the channels:read, channels:history and chat:write scopes, install it, and invite the bot to the channels it should see."
      credentialLabel="Bot User OAuth Token"
      placeholder="xoxb-…"
      onChange={onChange}
    />
  );
}
