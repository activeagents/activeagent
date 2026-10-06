import React, { useState, useEffect } from 'react';
import AgentList from '../components/dashboard/AgentList';
import AgentBuilder from '../components/dashboard/AgentBuilder';
import AgentEditor from '../components/dashboard/AgentEditor';
import AgentRunner from '../components/dashboard/AgentRunner';
import DashboardAnalytics from '../components/dashboard/DashboardAnalytics';
import AgentInteractions from '../components/dashboard/AgentInteractions';
import TemplateLibrary from '../components/dashboard/TemplateLibrary';
import Sidebar from '../components/dashboard/Sidebar';
import Header from '../components/dashboard/Header';
import TracesView from '../components/dashboard/TracesView';
import MetricsView from '../components/dashboard/MetricsView';
import InteractionsView from '../components/dashboard/InteractionsView';
import ToolsView from '../components/dashboard/ToolsView';
import McpServersView from '../components/dashboard/McpServersView';
import EvaluationsView from '../components/dashboard/EvaluationsView';
import SandboxRunner from '../components/dashboard/SandboxRunner';
import SessionReplayView from '../components/dashboard/SessionReplayView';
import OrganizationView from '../components/dashboard/OrganizationView';
import SettingsView from '../components/dashboard/SettingsView';
import DashboardAssistant from '../components/dashboard/DashboardAssistant';
import { ThemeProvider, useTheme } from '../contexts/ThemeContext';
import { TimeWindowProvider } from '../contexts/TimeWindowContext';
import { useInputRequests } from '../hooks/useInputRequests';
import { pendingBadge } from '../utils/inputRequests.mjs';
import { dashboardPath, dashboardRelativePath } from '../utils/dashboardPath';
import {
  dashboardFeatures,
  dashboardViewPath,
  isDashboardViewEnabled,
  matchDashboardRoute,
} from '../utils/dashboardRoutes.mjs';

/**
 * Dashboard - Main dashboard application
 *
 * Routes are handled client-side for SPA-like experience
 * Real routes still go through Rails/Inertia for SSR benefits
 */
function DashboardContent({ user, initialAgents = [], meta = {}, account = null, subscription = null }) {
  const { darkMode } = useTheme();
  const [agents, setAgents] = useState(initialAgents);
  const [currentView, setCurrentView] = useState('list'); // list, builder, editor, runner, analytics, agent-analytics, history
  const [selectedAgent, setSelectedAgent] = useState(null);
  const [isLoading, setIsLoading] = useState(false);
  const [notification, setNotification] = useState(null);
  const [showTemplateLibrary, setShowTemplateLibrary] = useState(false);
  const [agentSort, setAgentSort] = useState('recent');
  const [assistantSession, setAssistantSession] = useState({ messages: [] });
  const [builderDraft, setBuilderDraft] = useState(null);
  // What the server enabled. A view it turned off (the assistant, a
  // development and CI tool) has no nav item, no route and no view; the API
  // refuses the same way.
  const features = dashboardFeatures(meta);
  // Which MCP service the MCP view should open expanded — set when a tool
  // row links to the server that serves it, or from a /mcp/:server URL.
  const [focusServer, setFocusServer] = useState(null);
  // The Interactions badge: refetched whenever the view changes as well as on
  // the hook's own interval.
  const { requests: pendingInput } = useInputRequests({ refreshKey: currentView });

  // Parse the URL into a view. Runs on mount and on popstate, so browser
  // back/forward and in-app pushState navigation (e.g. a Traces agent card
  // opening its agent) both land on the right view.
  useEffect(() => {
    const applyPath = () => {
      // Relative to the mount: matched against the raw pathname, a mount like
      // /admin/agents made '/agents/' true for every URL and a mount like
      // /demo rendered the sandbox everywhere.
      const route = matchDashboardRoute(dashboardRelativePath(), features);
      if (route.focusServer) setFocusServer(route.focusServer);
      if (route.replacePath) window.history.replaceState({}, '', route.replacePath);
      if (route.agentId) loadAgent(route.agentId, route.view);
      else setCurrentView(route.view);
    };

    applyPath();
    // popstate: browser back/forward. dashboard:navigate: in-app pushState
    // (e.g. a Traces agent card opening its agent) — a custom event because
    // Inertia's own popstate handler rejects synthetic ones.
    window.addEventListener('popstate', applyPath);
    window.addEventListener('dashboard:navigate', applyPath);
    return () => {
      window.removeEventListener('popstate', applyPath);
      window.removeEventListener('dashboard:navigate', applyPath);
    };
  }, []);

  const loadAgent = async (id, view) => {
    setIsLoading(true);
    try {
      const response = await fetch(`/api/agents/${id}`);
      const data = await response.json();
      setSelectedAgent(data.agent);
      setCurrentView(view);
    } catch (error) {
      showNotification('Failed to load agent', 'error');
    } finally {
      setIsLoading(false);
    }
  };

  // Ranking is applied server-side (Api::AgentsController::LIST_SORTS) over
  // every agent and their scorecards, so changing it refetches rather than
  // reordering the array in place.
  const refreshAgents = async (sort = agentSort) => {
    setIsLoading(true);
    try {
      const response = await fetch(`/api/agents?sort=${sort}`);
      const data = await response.json();
      setAgents(data.agents);
    } catch (error) {
      showNotification('Failed to refresh agents', 'error');
    } finally {
      setIsLoading(false);
    }
  };

  const changeAgentSort = (sort) => {
    setAgentSort(sort);
    refreshAgents(sort);
  };

  const showNotification = (message, type = 'info') => {
    setNotification({ message, type });
    setTimeout(() => setNotification(null), 3000);
  };

  // Pushes the URL the view opens at; a view this dashboard does not have
  // pushes nothing.
  const pushViewPath = (view, agent = null) => {
    const path = dashboardViewPath(view, { agent, features });
    if (path !== null) window.history.pushState({}, '', dashboardPath(path));
  };

  const handleCreateAgent = async (agentData) => {
    setIsLoading(true);
    try {
      const response = await fetch('/api/agents', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ agent: agentData })
      });

      if (response.ok) {
        const data = await response.json();
        setAgents([data.agent, ...agents]);
        setSelectedAgent(data.agent);
        setCurrentView('editor');
        showNotification('Agent created successfully!', 'success');
        pushViewPath('editor', data.agent);
        return null;
      }

      // Handed back to the builder, which renders them on the form; a 422
      // from a validation is the common case, but any failure is reported.
      const error = await response.json().catch(() => ({}));
      const failure = {
        errors: error.errors?.length ? error.errors : [error.error || `Failed to create agent (${response.status})`],
        fieldErrors: error.field_errors || {},
      };
      showNotification(failure.errors.join(', '), 'error');
      return failure;
    } catch (error) {
      showNotification('Failed to create agent', 'error');
      return { errors: ['Failed to create agent: the request did not complete'], fieldErrors: {} };
    } finally {
      setIsLoading(false);
    }
  };

  const handleUpdateAgent = async (id, agentData) => {
    setIsLoading(true);
    try {
      const response = await fetch(`/api/agents/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ agent: agentData })
      });

      if (response.ok) {
        const data = await response.json();
        setAgents(agents.map(a => a.id === id ? data.agent : a));
        setSelectedAgent(data.agent);
        showNotification('Agent updated!', 'success');
      } else {
        const error = await response.json();
        showNotification(error.errors?.join(', ') || 'Failed to update agent', 'error');
      }
    } catch (error) {
      showNotification('Failed to update agent', 'error');
    } finally {
      setIsLoading(false);
    }
  };

  const handleDeleteAgent = async (id) => {
    if (!confirm('Are you sure you want to delete this agent?')) return;

    setIsLoading(true);
    try {
      const response = await fetch(`/api/agents/${id}`, { method: 'DELETE' });

      if (response.ok) {
        setAgents(agents.filter(a => a.id !== id));
        setSelectedAgent(null);
        setCurrentView('list');
        showNotification('Agent deleted', 'success');
        pushViewPath('list');
      }
    } catch (error) {
      showNotification('Failed to delete agent', 'error');
    } finally {
      setIsLoading(false);
    }
  };

  const handleDuplicateAgent = async (id) => {
    setIsLoading(true);
    try {
      const response = await fetch(`/api/agents/${id}/duplicate`, { method: 'POST' });

      if (response.ok) {
        const data = await response.json();
        setAgents([data.agent, ...agents]);
        showNotification('Agent duplicated!', 'success');
      }
    } catch (error) {
      showNotification('Failed to duplicate agent', 'error');
    } finally {
      setIsLoading(false);
    }
  };

  const handleUseTemplate = (agent) => {
    setAgents([agent, ...agents]);
    setShowTemplateLibrary(false);
    showNotification('Agent created from template!', 'success');
    // Through navigateTo rather than setSelectedAgent directly: it refetches
    // the full record whenever it is handed a summary, so the editor never
    // initializes from a shallow object and wipes the template's
    // instructions, tools and model_config on the first save.
    navigateTo('editor', agent);
  };

  // Views that edit or run an agent need its detail fields (instructions,
  // tools, ...). List-serialized agents lack them — initializing the editor
  // from one wipes those fields on the next save, so refetch the full
  // record whenever the shallow object is all we have.
  const AGENT_DETAIL_VIEWS = ['editor', 'runner', 'agent-analytics', 'history'];

  const navigateTo = (view, agent = null) => {
    if (!isDashboardViewEnabled(view, features)) return;
    if (view === 'builder') setBuilderDraft(null);
    if (agent?.id && AGENT_DETAIL_VIEWS.includes(view) && agent.instructions === undefined) {
      loadAgent(agent.id, view);
    } else {
      setSelectedAgent(agent);
      setCurrentView(view);
    }

    pushViewPath(view, agent);
  };

  // One renderer per view in utils/dashboardRoutes.mjs; the agent list is
  // also the fallback for a view without one.
  const views = {
    assistant: () => (
      <DashboardAssistant
        session={assistantSession}
        onSessionChange={setAssistantSession}
        executionEnabled={meta.executionEnabled !== false}
        onOpenSettings={() => navigateTo('settings')}
        onReviewDraft={draft => {
          setBuilderDraft(draft);
          setCurrentView('builder');
          pushViewPath('builder');
        }}
      />
    ),
    builder: () => (
      <AgentBuilder
        key={builderDraft?.id || 'new-agent'}
        initialDraft={builderDraft}
        meta={meta}
        onSave={handleCreateAgent}
        onCancel={() => navigateTo(builderDraft ? 'assistant' : 'list')}
        isLoading={isLoading}
      />
    ),
    editor: () => (selectedAgent ? (
      <AgentEditor
        key={`editor-${selectedAgent.id}`}
        agent={selectedAgent}
        meta={meta}
        onSave={(data) => handleUpdateAgent(selectedAgent.id, data)}
        onDelete={() => handleDeleteAgent(selectedAgent.id)}
        onRun={() => navigateTo('runner', selectedAgent)}
        onDuplicate={() => handleDuplicateAgent(selectedAgent.id)}
        onRunReport={() => navigateTo('history', selectedAgent)}
        onBack={() => navigateTo('list')}
        isLoading={isLoading}
      />
    ) : null),
    runner: () => (selectedAgent ? (
      <AgentRunner
        agent={selectedAgent}
        onBack={() => navigateTo('editor', selectedAgent)}
      />
    ) : null),
    // Per-agent analytics is a tab on the agent page now, so the old
    // /analytics deep link opens that page with the tab selected.
    'agent-analytics': () => (selectedAgent ? (
      <AgentEditor
        key={`agent-analytics-${selectedAgent.id}`}
        agent={selectedAgent}
        meta={meta}
        initialTab="metrics"
        onSave={(data) => handleUpdateAgent(selectedAgent.id, data)}
        onDelete={() => handleDeleteAgent(selectedAgent.id)}
        onRun={() => navigateTo('runner', selectedAgent)}
        onDuplicate={() => handleDuplicateAgent(selectedAgent.id)}
        onRunReport={() => navigateTo('history', selectedAgent)}
        onBack={() => navigateTo('list')}
        isLoading={isLoading}
      />
    ) : null),
    history: () => (selectedAgent ? (
      <AgentInteractions
        agent={selectedAgent}
        onBack={() => navigateTo('editor', selectedAgent)}
      />
    ) : null),
    analytics: () => (
      <DashboardAnalytics
        onSelectAgent={(agent) => {
          loadAgent(agent.id, 'agent-analytics');
        }}
      />
    ),
    traces: () => <TracesView />,
    metrics: () => <MetricsView />,
    interactions: () => <InteractionsView />,
    tools: () => (
      <ToolsView
        onOpenServer={(key) => {
          setFocusServer(key);
          navigateTo('mcp');
        }}
      />
    ),
    mcp: () => (
      <McpServersView
        focusServer={focusServer}
        onOpenTools={() => {
          setFocusServer(null);
          navigateTo('tools');
        }}
      />
    ),
    evaluations: () => <EvaluationsView />,
    replay: () => (
      <SessionReplayView
        onHandoff={(handoffData) => {
          // The agent stopped on a page only a person may finish (payment,
          // a login code). Open that page for them; the recording keeps
          // what the agent already entered.
          const state = handoffData?.handoff_state || {};
          if (state.url) window.open(state.url, '_blank', 'noopener,noreferrer');
          const entered = Object.entries(state.form_values || {}).map(([k, v]) => `${k}: ${v}`).join(' · ');
          showNotification(
            state.url
              ? `Taking over in a new tab${entered ? ` — already entered: ${entered}` : ''}`
              : 'Taking over session...',
            'info'
          );
        }}
        onClose={() => navigateTo('list')}
      />
    ),
    sandbox: () => (
      <SandboxRunner
        initialType="playwright_mcp"
        onClose={() => navigateTo('list')}
      />
    ),
    organization: () => (
      <OrganizationView
        user={user}
        account={account}
        subscription={subscription}
        agentCount={agents.length}
      />
    ),
    settings: () => <SettingsView user={user} />,
    list: () => (
      <AgentList
        agents={agents}
        meta={meta}
        onSelect={(agent) => navigateTo('editor', agent)}
        onNew={() => navigateTo('builder')}
        onBrowseTemplates={() => setShowTemplateLibrary(true)}
        onDuplicate={handleDuplicateAgent}
        onDelete={handleDeleteAgent}
        onRefresh={refreshAgents}
        sort={agentSort}
        onSortChange={changeAgentSort}
        isLoading={isLoading}
      />
    ),
  };

  const renderContent = () => {
    if (!isDashboardViewEnabled(currentView, features)) return null;
    return (views[currentView] || views.list)();
  };

  return (
    <div
      // aa-dashboard scopes the design token layer (frontend/tokens.css); the
      // theme class switches it to the dark palette for every descendant.
      className={`aa-dashboard min-h-screen flex${darkMode ? ' theme-dark' : ''}`}
      style={{ backgroundColor: darkMode ? '#0f0f0f' : '#f9fafb' }}
    >
      <Sidebar
        currentView={currentView}
        onNavigate={navigateTo}
        agentCount={agents.length}
        pendingInputCount={pendingBadge(pendingInput)}
        account={account}
        user={user}
        gemVersion={meta.activeagentVersion}
        features={features}
      />

      {/* min-w-0: a flex item defaults to min-width:auto, so a view whose
          content is wider than the viewport — a long toolbar, a wide table —
          stretches this column instead of scrolling inside it, and the whole
          page scrolls sideways. */}
      <div className="flex-1 flex flex-col min-w-0">
        <Header
          user={user}
          account={account}
        />

        <main className="flex-1 p-6 overflow-auto">
          {renderContent()}
        </main>
      </div>

      {/* Template Library Modal */}
      {showTemplateLibrary && (
        <TemplateLibrary
          onUseTemplate={handleUseTemplate}
          onClose={() => setShowTemplateLibrary(false)}
        />
      )}

      {/* Notification Toast */}
      {notification && (
        <div className={`fixed bottom-4 right-4 z-[60] px-6 py-3 rounded-lg shadow-lg transition-all transform ${
          notification.type === 'error' ? 'bg-red-500' :
          notification.type === 'success' ? 'bg-green-500' : 'bg-blue-500'
        } text-white`}>
          {notification.message}
        </div>
      )}

      {/* Loading Overlay */}
      {isLoading && (
        <div className="fixed inset-0 bg-black bg-opacity-20 flex items-center justify-center z-50">
          <div className={`rounded-lg p-4 shadow-xl ${darkMode ? 'bg-gray-800' : 'bg-white'}`}>
            <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-red-500"></div>
          </div>
        </div>
      )}
    </div>
  );
}

// Wrap with ThemeProvider and TimeWindowProvider. The time window is
// app-level so it survives navigation between views.
export default function Dashboard(props) {
  return (
    <ThemeProvider>
      <TimeWindowProvider>
        <DashboardContent {...props} />
      </TimeWindowProvider>
    </ThemeProvider>
  );
}
