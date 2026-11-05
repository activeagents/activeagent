import React from 'react';
import AgentAvatar from '../AgentAvatar';
import { Button, Card, MicroLabel, MONO } from './primitives';
import { navigateTo } from '../../utils/dashboardPath';
import { telemetryConfigSnippet } from '../../utils/telemetrySetup.mjs';

const DOCS_TELEMETRY_URL = 'https://docs.activeagents.ai/framework/telemetry';

const codeStyle = {
  fontFamily: MONO, fontSize: 12, padding: '1px 4px', borderRadius: 4,
  background: 'var(--color-hover)', color: 'var(--color-text-primary)',
};

const preStyle = {
  margin: 0, padding: 12, borderRadius: 8, overflowX: 'auto', textAlign: 'left',
  fontFamily: MONO, fontSize: 11, lineHeight: 1.5,
  background: '#111827', color: '#f3f4f6',
};

const bodyStyle = { margin: 0, fontSize: 13, lineHeight: 1.5, color: 'var(--color-text-secondary)' };

function Way({ label, title, children, testId }) {
  return (
    <Card testId={testId} style={{ display: 'flex', flexDirection: 'column', gap: 12, textAlign: 'left', minWidth: 0 }}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
        <MicroLabel>{label}</MicroLabel>
        <h4 style={{ margin: 0, fontSize: 15, fontWeight: 600, color: 'var(--color-text-primary)' }}>{title}</h4>
      </div>
      {children}
    </Card>
  );
}

// The agent list before there is an agent. Most agents arrive from an app
// that already runs ActiveAgent: its first trace registers them
// (AgentRegistrar), so reporting telemetry comes first. A GitHub repository
// booted as a project is the second way in, and building one here the third.
export default function AgentsEmptyState({ endpoint, multiTenant, onRefresh, isLoading, onBrowseTemplates, onNew }) {
  return (
    <div className="py-10 max-md:py-6" data-testid="agents-empty-state">
      <div className="text-center">
        <div className="inline-block mb-4">
          <AgentAvatar size={88} />
        </div>
        <h3 style={{ margin: '0 0 8px', fontSize: 18, fontWeight: 500, color: 'var(--color-text-primary)' }}>No agents yet</h3>
        <p style={{ margin: '0 0 32px', fontSize: 15, color: 'var(--color-text-secondary)' }}>
          Agents appear here when your app reports its first trace, when you link a repository, or when you build one.
        </p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4 max-w-6xl mx-auto">
        <Way label="From your app" title="Connect your app" testId="empty-connect-telemetry">
          <p style={bodyStyle}>
            Already running ActiveAgent? Add this to <code style={codeStyle}>config/active_agent.yml</code> and
            every agent action that runs shows up here on its first trace.
          </p>
          <pre style={preStyle}>{telemetryConfigSnippet(endpoint)}</pre>
          <p style={bodyStyle}>
            {multiTenant ? (
              <>
                Set <code style={codeStyle}>ACTIVEAGENTS_API_KEY</code> to this workspace&apos;s telemetry key, on the
                Organization page.
              </>
            ) : (
              <>
                Set <code style={codeStyle}>ACTIVEAGENTS_API_KEY</code> to the dashboard&apos;s{' '}
                <code style={codeStyle}>ingest_api_key</code>, when it has one.
              </>
            )}
          </p>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginTop: 'auto' }}>
            {multiTenant && (
              <Button variant="primary" size="sm" onClick={() => navigateTo('/organization')} testId="empty-telemetry-key">
                Get the telemetry key
              </Button>
            )}
            <Button size="sm" onClick={onRefresh} disabled={isLoading} testId="empty-check-again">
              {isLoading ? 'Checking…' : 'Check for agents'}
            </Button>
            <a href={DOCS_TELEMETRY_URL} target="_blank" rel="noopener noreferrer" style={{ alignSelf: 'center', fontSize: 13, color: 'var(--color-info)' }}>
              Telemetry docs
            </a>
          </div>
        </Way>

        <Way label="From GitHub" title="Link a GitHub repository" testId="empty-link-repository">
          <p style={bodyStyle}>
            Connect GitHub and pick a Rails app. The dashboard boots it in a sandbox, opens a pull request to install
            the engine when it is missing, and lets Claude Code work on the app&apos;s agents there.
          </p>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginTop: 'auto' }}>
            <Button variant="primary" size="sm" onClick={() => navigateTo('/projects/new')} testId="empty-new-project">
              Link a repository
            </Button>
          </div>
        </Way>

        <Way label="From scratch" title="Build one here" testId="empty-build-agent">
          <p style={bodyStyle}>
            Start from a template or write the instructions yourself, then run it from the dashboard.
          </p>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginTop: 'auto' }}>
            <Button size="sm" onClick={onBrowseTemplates} testId="empty-browse-templates">Browse Templates</Button>
            <Button size="sm" onClick={onNew} testId="empty-create-agent">Create From Scratch</Button>
          </div>
        </Way>
      </div>
    </div>
  );
}
