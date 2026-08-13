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
import EvaluationsView from '../components/dashboard/EvaluationsView';
import SandboxRunner from '../components/dashboard/SandboxRunner';
import SessionReplayView from '../components/dashboard/SessionReplayView';
import OrganizationView from '../components/dashboard/OrganizationView';
import SettingsView from '../components/dashboard/SettingsView';
import { ThemeProvider, useTheme } from '../contexts/ThemeContext';
import { TimeWindowProvider } from '../contexts/TimeWindowContext';
import { dashboardPath } from '../utils/dashboardPath';

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

  // Parse the URL into a view. Runs on mount and on popstate, so browser
  // back/forward and in-app pushState navigation (e.g. a Traces agent card
  // opening its agent) both land on the right view.
  useEffect(() => {
    const applyPath = () => {
    const path = window.location.pathname;
    if (path.includes('/traces')) {
      setCurrentView('traces');
    } else if (path.includes('/metrics')) {
      setCurrentView('metrics');
    } else if (path.includes('/interactions') && !path.includes('/agents/')) {
      setCurrentView('interactions');
    } else if (path.includes('/evaluations')) {
      setCurrentView('evaluations');
    } else if (path.includes('/analytics') && !path.includes('/agents/')) {
      setCurrentView('analytics');
    } else if (path.includes('/agents/new')) {
      setCurrentView('builder');
    } else if (path.match(/\/agents\/\d+\/(interactions|history)/)) {
      const id = path.match(/\/agents\/(\d+)/)?.[1];
      // Legacy /history URLs normalize to /interactions before the view
      // mounts, so nested-path parsing sees the canonical form.
      if (path.includes('/history')) {
        window.history.replaceState({}, '', path.replace('/history', '/interactions'));
      }
      if (id) loadAgent(id, 'history');
    } else if (path.match(/\/agents\/\d+\/analytics/)) {
      const id = path.match(/\/agents\/(\d+)/)?.[1];
      if (id) loadAgent(id, 'agent-analytics');
    } else if (path.match(/\/agents\/\d+\/edit/)) {
      const id = path.match(/\/agents\/(\d+)/)?.[1];
      if (id) loadAgent(id, 'editor');
    } else if (path.match(/\/agents\/\d+\/run/)) {
      const id = path.match(/\/agents\/(\d+)/)?.[1];
      if (id) loadAgent(id, 'runner');
    } else if (path.match(/\/agents\/\d+\/?$/)) {
      // Bare /dashboard/agents/:id — previously fell through to the agent
      // list. Its detail view is the interactions/runs stream, which drills
      // down into individual traces.
      const id = path.match(/\/agents\/(\d+)/)?.[1];
      if (id) loadAgent(id, 'history');
    } else if (path.includes('/benchmarks')) {
      setCurrentView('benchmarks');
    } else if (path.includes('/replay')) {
      setCurrentView('replay');
    } else if (path.includes('/sandbox') || path.includes('/demo')) {
      setCurrentView('sandbox');
    } else if (path.includes('/organization')) {
      setCurrentView('organization');
    } else if (path.includes('/settings')) {
      setCurrentView('settings');
    } else {
      setCurrentView('list');
    }
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
        window.history.pushState({}, '', dashboardPath(`/agents/${data.agent.id}/edit`));
      } else {
        const error = await response.json();
        showNotification(error.errors?.join(', ') || 'Failed to create agent', 'error');
      }
    } catch (error) {
      showNotification('Failed to create agent', 'error');
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
        window.history.pushState({}, '', dashboardPath());
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
    setSelectedAgent(agent);
    setCurrentView('editor');
    setShowTemplateLibrary(false);
    showNotification('Agent created from template!', 'success');
    window.history.pushState({}, '', dashboardPath(`/agents/${agent.id}/edit`));
  };

  // Views that edit or run an agent need its detail fields (instructions,
  // tools, ...). List-serialized agents lack them — initializing the editor
  // from one wipes those fields on the next save, so refetch the full
  // record whenever the shallow object is all we have.
  const AGENT_DETAIL_VIEWS = ['editor', 'runner', 'agent-analytics', 'history'];

  const navigateTo = (view, agent = null) => {
    if (agent?.id && AGENT_DETAIL_VIEWS.includes(view) && agent.instructions === undefined) {
      loadAgent(agent.id, view);
    } else {
      setSelectedAgent(agent);
      setCurrentView(view);
    }

    // Update URL
    let path = dashboardPath();
    if (view === 'builder') path = dashboardPath('/agents/new');
    else if (view === 'editor' && agent) path = dashboardPath(`/agents/${agent.id}/edit`);
    else if (view === 'runner' && agent) path = dashboardPath(`/agents/${agent.id}/run`);
    else if (view === 'agent-analytics' && agent) path = dashboardPath(`/agents/${agent.id}/analytics`);
    else if (view === 'history' && agent) path = dashboardPath(`/agents/${agent.id}/interactions`);
    else if (view === 'analytics') path = dashboardPath('/analytics');
    else if (view === 'traces') path = dashboardPath('/traces');
    else if (view === 'metrics') path = dashboardPath('/metrics');
    else if (view === 'interactions') path = dashboardPath('/interactions');
    else if (view === 'evaluations') path = dashboardPath('/evaluations');
    else if (view === 'benchmarks') path = dashboardPath('/benchmarks');
    else if (view === 'replay') path = dashboardPath('/replay');
    else if (view === 'sandbox') path = dashboardPath('/sandbox');
    else if (view === 'organization') path = dashboardPath('/organization');
    else if (view === 'settings') path = dashboardPath('/settings');

    window.history.pushState({}, '', path);
  };

  const renderContent = () => {
    switch (currentView) {
      case 'builder':
        return (
          <AgentBuilder
            meta={meta}
            onSave={handleCreateAgent}
            onCancel={() => navigateTo('list')}
            isLoading={isLoading}
          />
        );
      case 'editor':
        return selectedAgent ? (
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
        ) : null;
      case 'runner':
        return selectedAgent ? (
          <AgentRunner
            agent={selectedAgent}
            onBack={() => navigateTo('editor', selectedAgent)}
          />
        ) : null;
      // Per-agent analytics is a tab on the agent page now, so the old
      // /analytics deep link opens that page with the tab selected.
      case 'agent-analytics':
        return selectedAgent ? (
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
        ) : null;
      case 'history':
        return selectedAgent ? (
          <AgentInteractions
            agent={selectedAgent}
            onBack={() => navigateTo('editor', selectedAgent)}
          />
        ) : null;
      case 'analytics':
        return (
          <DashboardAnalytics
            onSelectAgent={(agent) => {
              loadAgent(agent.id, 'agent-analytics');
            }}
          />
        );
      case 'traces':
        return <TracesView />;
      case 'metrics':
        return <MetricsView />;
      case 'interactions':
        return <InteractionsView />;
      case 'evaluations':
        return <EvaluationsView />;
      case 'replay':
        return (
          <SessionReplayView
            onHandoff={(handoffData) => {
              // When user takes over, navigate to sandbox with handoff state
              showNotification('Taking over session...', 'info');
              navigateTo('sandbox');
            }}
            onClose={() => navigateTo('list')}
          />
        );
      case 'sandbox':
        return (
          <SandboxRunner
            initialType="playwright_mcp"
            onClose={() => navigateTo('list')}
          />
        );
      case 'organization':
        return (
          <OrganizationView
            user={user}
            account={account}
            subscription={subscription}
            agentCount={agents.length}
          />
        );
      case 'settings':
        return <SettingsView user={user} />;
      default:
        return (
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
        );
    }
  };

  return (
    <div
      className="min-h-screen flex"
      style={{ backgroundColor: darkMode ? '#0f0f0f' : '#f9fafb' }}
    >
      <Sidebar
        currentView={currentView}
        onNavigate={navigateTo}
        agentCount={agents.length}
        account={account}
        user={user}
        gemVersion={meta.activeagentVersion}
      />

      <div className="flex-1 flex flex-col">
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
        <div className={`fixed bottom-4 right-4 px-6 py-3 rounded-lg shadow-lg transition-all transform ${
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
