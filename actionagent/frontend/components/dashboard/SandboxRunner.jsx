import React, { useState, useEffect, useRef, useCallback } from 'react';
import AgentAvatar from '../AgentAvatar';
import { useActionCable } from '../../hooks/useActionCable';
import { startCheckout } from '../../utils/checkout';

const PROVIDERS = [
  { id: 'anthropic', name: 'Anthropic', model: 'claude-haiku-4-5', color: 'bg-orange-500' },
  { id: 'openai', name: 'OpenAI', model: 'gpt-4o', color: 'bg-green-500' },
  { id: 'ollama', name: 'Ollama', model: 'llama3.1:8b', color: 'bg-purple-500' },
];

const SAMPLE_TASKS = {
  playwright_mcp: [
    {
      name: "Screenshot Example.com",
      task: "Take a screenshot of https://example.com",
      description: "Navigate to example.com and capture a screenshot"
    },
    {
      name: "Extract Hacker News Headlines",
      task: "Go to https://news.ycombinator.com and list the top 5 story titles with their scores",
      description: "Scrape the front page of Hacker News"
    },
    {
      name: "Check Wikipedia",
      task: "Navigate to https://en.wikipedia.org/wiki/Artificial_intelligence and extract the first paragraph",
      description: "Extract content from Wikipedia"
    },
    {
      name: "GitHub Trending",
      task: "Visit https://github.com/trending and list the top 3 trending repositories",
      description: "Check GitHub's trending repositories"
    }
  ],
  comparison: [
    {
      name: "Explain Ruby Blocks",
      task: "Explain how Ruby blocks work with a simple example",
      description: "Compare how each model explains Ruby concepts"
    },
    {
      name: "Write a Haiku",
      task: "Write a haiku about programming",
      description: "Compare creative output across models"
    },
    {
      name: "Debug This Code",
      task: "What's wrong with this code? def add(a, b); a - b; end; puts add(2, 3)",
      description: "Compare debugging abilities"
    },
    {
      name: "Summarize AI",
      task: "Summarize the current state of AI in 3 sentences",
      description: "Compare factual knowledge and conciseness"
    }
  ]
};

const FREE_TIER_LIMITS = {
  max_runs: 10,
  timeout_seconds: 300,
  session_duration_minutes: 15
};

export default function SandboxRunner({ initialType = 'playwright_mcp', onClose }) {
  const [sandboxType, setSandboxType] = useState(initialType);
  const [session, setSession] = useState(null);
  const [task, setTask] = useState('');
  const [runs, setRuns] = useState([]);
  const [currentRun, setCurrentRun] = useState(null);
  const [isRunning, setIsRunning] = useState(false);
  const [isCreating, setIsCreating] = useState(false);
  const [error, setError] = useState(null);
  const [timeRemaining, setTimeRemaining] = useState(null);
  const [showUpgradeModal, setShowUpgradeModal] = useState(false);
  const [usage, setUsage] = useState(null);
  const [isCheckingOut, setIsCheckingOut] = useState(false);
  const outputRef = useRef(null);

  // Provider comparison state
  const [selectedProviders, setSelectedProviders] = useState(['anthropic']);
  const [comparisonMode, setComparisonMode] = useState(false);
  const [comparisonResults, setComparisonResults] = useState({});
  const [runningProviders, setRunningProviders] = useState([]);

  // ActionCable message handler
  const handleCableMessage = useCallback((data) => {
    console.log('[SandboxRunner] Received ActionCable message:', data);

    switch (data.type) {
      case 'run_started':
        // Update comparison results to show this provider is running
        if (comparisonMode) {
          setComparisonResults(prev => ({
            ...prev,
            [data.provider]: {
              status: 'running',
              started_at: data.started_at,
              provider: data.provider
            }
          }));
        } else {
          setCurrentRun(prev => ({
            ...prev,
            status: 'running',
            provider: data.provider
          }));
        }
        break;

      case 'run_complete':
        if (comparisonMode) {
          setComparisonResults(prev => ({
            ...prev,
            [data.provider]: { ...data.run, provider: data.provider }
          }));
          setRunningProviders(prev => prev.filter(p => p !== data.provider));

          // Update session from broadcast
          if (data.sandbox) {
            setSession(data.sandbox);
            setRuns(data.sandbox.runs || []);
          }
        } else {
          setCurrentRun(data.run);
          setIsRunning(false);
          if (data.sandbox) {
            setSession(data.sandbox);
            setRuns(data.sandbox.runs || []);
          }
        }

        // Check if all providers are done
        setRunningProviders(prev => {
          const remaining = prev.filter(p => p !== data.provider);
          if (remaining.length === 0) {
            setIsRunning(false);
          }
          return remaining;
        });
        break;

      case 'run_error':
        if (comparisonMode) {
          setComparisonResults(prev => ({
            ...prev,
            [data.provider]: {
              status: 'failed',
              error: data.error,
              provider: data.provider
            }
          }));
          setRunningProviders(prev => prev.filter(p => p !== data.provider));
        } else {
          setCurrentRun(prev => ({
            ...prev,
            status: 'failed',
            error: data.error
          }));
          setIsRunning(false);
        }

        if (data.sandbox) {
          setSession(data.sandbox);
        }
        break;
    }
  }, [comparisonMode]);

  // Subscribe to ActionCable when session is available
  useActionCable(
    'SandboxChannel',
    { session_id: session?.session_id },
    handleCableMessage,
    !!session?.session_id
  );

  // Create session on mount and fetch usage
  useEffect(() => {
    createSession();
    fetchUsage();
  }, [sandboxType]);

  const fetchUsage = async () => {
    try {
      const response = await fetch('/api/usage');
      if (response.ok) {
        const data = await response.json();
        setUsage(data.usage);
      }
    } catch (err) {
      console.log('Could not fetch usage (user may not be authenticated)');
    }
  };

  // Countdown timer
  useEffect(() => {
    if (!session?.expires_at) return;

    const interval = setInterval(() => {
      const now = new Date();
      const expires = new Date(session.expires_at);
      const remaining = Math.max(0, Math.floor((expires - now) / 1000));
      setTimeRemaining(remaining);

      if (remaining === 0) {
        setSession(prev => ({ ...prev, status: 'expired' }));
        clearInterval(interval);
      }
    }, 1000);

    return () => clearInterval(interval);
  }, [session?.expires_at]);

  // Auto-scroll output
  useEffect(() => {
    if (outputRef.current) {
      outputRef.current.scrollTop = outputRef.current.scrollHeight;
    }
  }, [currentRun?.result]);

  const createSession = async () => {
    setIsCreating(true);
    setError(null);

    try {
      const response = await fetch('/api/sandboxes', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ sandbox_type: sandboxType })
      });

      if (!response.ok) {
        throw new Error('Failed to create sandbox session');
      }

      const data = await response.json();
      setSession(data.sandbox);
      setRuns([]);
      setCurrentRun(null);
    } catch (err) {
      setError(err.message);
    } finally {
      setIsCreating(false);
    }
  };

  const handleRun = async () => {
    if (!task.trim() || isRunning || !session) return;

    if (comparisonMode && selectedProviders.length > 1) {
      // Run comparison across multiple providers
      await runComparison();
    } else {
      // Single provider run
      await runSingleProvider(selectedProviders[0] || 'anthropic');
    }
  };

  const runSingleProvider = async (provider) => {
    setIsRunning(true);
    setCurrentRun({
      status: 'running',
      task: task,
      provider: provider,
      result: '',
      started_at: new Date().toISOString()
    });

    try {
      const response = await fetch(`/api/sandboxes/${session.session_id}/run`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ task: task, provider: provider })
      });

      const data = await response.json();

      // Handle upgrade required (402 Payment Required)
      if (response.status === 402 && data.upgrade_required) {
        setUsage(data.usage);
        setShowUpgradeModal(true);
        setCurrentRun(prev => ({
          ...prev,
          status: 'failed',
          error: data.message || 'Plan limit reached'
        }));
        setIsRunning(false);
        return;
      }

      if (!response.ok) {
        throw new Error(data.error || 'Task execution failed');
      }

      // Update usage from response
      if (data.usage) {
        setUsage(data.usage);
      }

      // Poll for completion
      pollRunStatus(data.run_id);
    } catch (err) {
      setCurrentRun(prev => ({
        ...prev,
        status: 'failed',
        error: err.message
      }));
      setIsRunning(false);
    }
  };

  const runComparison = async () => {
    setIsRunning(true);
    setRunningProviders([...selectedProviders]);
    setComparisonResults({});

    // Initialize all as running
    const initialResults = {};
    selectedProviders.forEach(p => {
      initialResults[p] = { status: 'running', result: '', started_at: new Date().toISOString() };
    });
    setComparisonResults(initialResults);

    try {
      // Use compare endpoint with existing sandbox - spawns multiple generation jobs
      // ActionCable will handle real-time updates via the subscription
      const response = await fetch('/api/sandboxes/compare', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          task: task,
          providers: selectedProviders,
          sandbox_id: session?.session_id,
          sandbox_type: sandboxType
        })
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Comparison failed');
      }

      const data = await response.json();

      // Update session if returned
      if (data.sandbox) {
        setSession(data.sandbox);
      }

      // ActionCable will handle the real-time updates
      // Set a timeout fallback in case ActionCable doesn't work
      setTimeout(() => {
        // If still running after 60s, poll for status
        if (runningProviders.length > 0) {
          pollForCompletion();
        }
      }, 60000);

    } catch (err) {
      selectedProviders.forEach(provider => {
        setComparisonResults(prev => ({
          ...prev,
          [provider]: { status: 'failed', error: err.message }
        }));
      });
      setIsRunning(false);
      setRunningProviders([]);
    }
  };

  // Fallback polling if ActionCable doesn't deliver
  const pollForCompletion = async () => {
    if (!session?.session_id) return;

    try {
      const response = await fetch(`/api/sandboxes/${session.session_id}`);
      const data = await response.json();

      setSession(data.sandbox);
      setRuns(data.sandbox.runs || []);

      // Update comparison results from runs
      const runs = data.sandbox.runs || [];
      runs.forEach(run => {
        if (run.provider) {
          setComparisonResults(prev => ({
            ...prev,
            [run.provider]: { ...run, provider: run.provider }
          }));
        }
      });

      // Check if all done
      const allComplete = selectedProviders.every(p => {
        const result = comparisonResults[p];
        return result?.status === 'completed' || result?.status === 'failed';
      });

      if (allComplete) {
        setIsRunning(false);
        setRunningProviders([]);
      }
    } catch (err) {
      console.error('Polling error:', err);
    }
  };

  const toggleProvider = (providerId) => {
    setSelectedProviders(prev => {
      if (prev.includes(providerId)) {
        // Don't allow deselecting the last provider
        if (prev.length === 1) return prev;
        return prev.filter(p => p !== providerId);
      } else {
        return [...prev, providerId];
      }
    });
  };

  const pollRunStatus = async (runId) => {
    const checkStatus = async () => {
      try {
        const response = await fetch(`/api/sandboxes/${session.session_id}`);
        const data = await response.json();

        setSession(data.sandbox);

        // Find the latest run
        const runs = data.sandbox.runs || [];
        const latestRun = runs[runs.length - 1];

        if (latestRun) {
          setCurrentRun(latestRun);
          setRuns(runs);

          if (latestRun.status === 'completed' || latestRun.status === 'failed') {
            setIsRunning(false);
            return;
          }
        }

        // Continue polling
        setTimeout(checkStatus, 1000);
      } catch (err) {
        setIsRunning(false);
      }
    };

    checkStatus();
  };

  const handleKeyDown = (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      handleRun();
    }
  };

  const formatTime = (seconds) => {
    if (!seconds) return '--:--';
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  };

  const getStatusColor = (status) => {
    switch (status) {
      case 'completed': return 'text-green-600 bg-green-100';
      case 'failed': return 'text-red-600 bg-red-100';
      case 'running': return 'text-blue-600 bg-blue-100';
      case 'ready': return 'text-emerald-600 bg-emerald-100';
      case 'expired': return 'text-orange-600 bg-orange-100';
      default: return 'text-gray-600 bg-gray-100';
    }
  };

  const canRun = session?.status === 'ready' &&
                 session?.runs_count < session?.max_runs &&
                 !isRunning;

  const handleUpgrade = async (billingInterval = 'monthly') => {
    setIsCheckingOut(true);
    try {
      await startCheckout({ planSlug: 'pro', billingInterval });
    } catch (err) {
      console.error('Checkout error:', err);
      setError(err.message || 'Failed to initiate checkout. Please try again.');
      setIsCheckingOut(false);
    }
  };

  return (
    <div className="h-full flex flex-col bg-gray-50">
      {/* Header */}
      <div className="bg-white border-b border-gray-200 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center space-x-4">
            <AgentAvatar
              size={48}
              appearance={{ hat: 'fedora', hatAccessory: 'theaterMasks', heldItem: 'browser' }}
            />
            <div>
              <h1 className="text-xl font-semibold text-gray-900">
                PlaywrightMCP Demo
              </h1>
              <p className="text-sm text-gray-500">
                Try browser automation for free - no account required
              </p>
            </div>
          </div>

          <div className="flex items-center space-x-4">
            {/* Session Status */}
            {session && (
              <div className="flex items-center space-x-3 text-sm">
                <span className={`px-2 py-1 rounded-full text-xs font-medium ${getStatusColor(session.status)}`}>
                  {session.status}
                </span>
                <span className="text-gray-500">
                  {session.runs_count}/{session.max_runs} runs
                </span>
                <span className={`font-mono ${timeRemaining < 60 ? 'text-red-500' : 'text-gray-500'}`}>
                  {formatTime(timeRemaining)}
                </span>
              </div>
            )}

            {onClose && (
              <button
                onClick={onClose}
                className="text-gray-400 hover:text-gray-600"
              >
                <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            )}
          </div>
        </div>
      </div>

      {/* Main Content */}
      <div className="flex-1 p-6 overflow-hidden">
        <div className="grid grid-cols-3 gap-6 h-full">
          {/* Main Runner */}
          <div className="col-span-2 flex flex-col space-y-4">
            {/* Input */}
            <div className="bg-white rounded-xl border border-gray-200 p-4">
              <textarea
                value={task}
                onChange={(e) => setTask(e.target.value)}
                onKeyDown={handleKeyDown}
                placeholder="Describe what you want the browser agent to do..."
                rows={3}
                disabled={!canRun}
                className="w-full px-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-rose-500 focus:border-transparent resize-none disabled:bg-gray-100"
              />
              <div className="flex items-center justify-between mt-3">
                <span className="text-xs text-gray-400">
                  Press <kbd className="px-1.5 py-0.5 bg-gray-100 rounded text-gray-600">Cmd</kbd> + <kbd className="px-1.5 py-0.5 bg-gray-100 rounded text-gray-600">Enter</kbd> to run
                </span>
                <button
                  onClick={handleRun}
                  disabled={!task.trim() || !canRun}
                  className={`flex items-center space-x-2 px-6 py-2 rounded-lg transition-colors ${
                    task.trim() && canRun
                      ? 'bg-rose-500 text-white hover:bg-rose-600'
                      : 'bg-gray-200 text-gray-400 cursor-not-allowed'
                  }`}
                >
                  {isRunning ? (
                    <>
                      <span className="animate-spin">&#9696;</span>
                      <span>Running...</span>
                    </>
                  ) : (
                    <>
                      <span>&#9654;</span>
                      <span>Run</span>
                    </>
                  )}
                </button>
              </div>
            </div>

            {/* Output */}
            <div className="flex-1 bg-white rounded-xl border border-gray-200 flex flex-col overflow-hidden">
              <div className="px-4 py-3 border-b border-gray-200 flex items-center justify-between">
                <h3 className="font-medium text-gray-900">
                  {comparisonMode && Object.keys(comparisonResults).length > 0 ? 'Comparison Results' : 'Output'}
                </h3>
                {currentRun && !comparisonMode && (
                  <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${getStatusColor(currentRun.status)}`}>
                    {currentRun.status}
                  </span>
                )}
                {comparisonMode && runningProviders.length > 0 && (
                  <span className="text-xs text-blue-600">
                    Running {runningProviders.length} provider(s)...
                  </span>
                )}
              </div>

              <div
                ref={outputRef}
                className="flex-1 overflow-auto bg-gray-50"
              >
                {isCreating ? (
                  <div className="flex items-center justify-center h-full text-gray-500 p-4">
                    <span className="animate-pulse">Starting sandbox...</span>
                  </div>
                ) : error ? (
                  <div className="text-red-600 p-4">{error}</div>
                ) : comparisonMode && Object.keys(comparisonResults).length > 0 ? (
                  /* Comparison View */
                  <div className="grid grid-cols-1 divide-y divide-gray-200">
                    {selectedProviders.map((providerId) => {
                      const provider = PROVIDERS.find(p => p.id === providerId);
                      const result = comparisonResults[providerId];
                      return (
                        <div key={providerId} className="p-4">
                          <div className="flex items-center justify-between mb-2">
                            <div className="flex items-center space-x-2">
                              <div className={`w-3 h-3 rounded-full ${provider?.color || 'bg-gray-400'}`} />
                              <span className="font-medium text-gray-900">{provider?.name || providerId}</span>
                              <span className="text-xs text-gray-500">{provider?.model}</span>
                            </div>
                            {result && (
                              <div className="flex items-center space-x-2">
                                <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${getStatusColor(result.status)}`}>
                                  {result.status}
                                </span>
                                {result.tokens && (
                                  <span className="text-xs text-gray-500">{result.tokens} tokens</span>
                                )}
                                {result.duration_ms && (
                                  <span className="text-xs text-gray-500">{(result.duration_ms / 1000).toFixed(1)}s</span>
                                )}
                              </div>
                            )}
                          </div>
                          <div className="bg-white rounded-lg border border-gray-200 p-3 font-mono text-sm max-h-48 overflow-auto">
                            {result?.status === 'running' ? (
                              <div className="flex items-center space-x-2 text-gray-500">
                                <span className="animate-pulse">&#9679;</span>
                                <span>Processing...</span>
                              </div>
                            ) : result?.error ? (
                              <div className="text-red-600">{result.error}</div>
                            ) : result?.result ? (
                              <pre className="whitespace-pre-wrap text-gray-800">{result.result}</pre>
                            ) : (
                              <span className="text-gray-400">Waiting...</span>
                            )}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                ) : currentRun ? (
                  /* Single Provider View */
                  <div className="p-4 font-mono text-sm">
                    {currentRun.provider && (
                      <div className="flex items-center space-x-2 mb-3 pb-2 border-b border-gray-200">
                        <div className={`w-2 h-2 rounded-full ${PROVIDERS.find(p => p.id === currentRun.provider)?.color || 'bg-gray-400'}`} />
                        <span className="text-sm text-gray-600">
                          {PROVIDERS.find(p => p.id === currentRun.provider)?.name || currentRun.provider}
                        </span>
                      </div>
                    )}
                    {currentRun.status === 'running' ? (
                      <div className="flex items-center space-x-2 text-gray-500">
                        <span className="animate-pulse">&#9679;</span>
                        <span>Executing task...</span>
                      </div>
                    ) : currentRun.error ? (
                      <div className="text-red-600">
                        <div className="font-semibold mb-2">Error:</div>
                        <pre className="whitespace-pre-wrap">{currentRun.error}</pre>
                      </div>
                    ) : (
                      <pre className="whitespace-pre-wrap text-gray-800">
                        {currentRun.result || 'Processing...'}
                      </pre>
                    )}
                  </div>
                ) : (
                  <div className="text-gray-400 text-center py-12">
                    <p className="mb-2">Select a sample task or enter your own</p>
                    <p className="text-xs">
                      {comparisonMode
                        ? `Compare results across ${selectedProviders.length} providers`
                        : 'Task will execute using the selected provider'}
                    </p>
                  </div>
                )}
              </div>
            </div>
          </div>

          {/* Sidebar */}
          <div className="space-y-4 overflow-auto">
            {/* Provider Selection */}
            <div className="bg-white rounded-xl border border-gray-200 p-4">
              <div className="flex items-center justify-between mb-3">
                <h4 className="font-medium text-gray-900">Providers</h4>
                <label className="flex items-center space-x-2 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={comparisonMode}
                    onChange={(e) => setComparisonMode(e.target.checked)}
                    className="rounded border-gray-300 text-rose-500 focus:ring-rose-500"
                  />
                  <span className="text-xs text-gray-600">Compare</span>
                </label>
              </div>
              <div className="space-y-2">
                {PROVIDERS.map((provider) => (
                  <label
                    key={provider.id}
                    className={`flex items-center justify-between p-2 rounded-lg border cursor-pointer transition-colors ${
                      selectedProviders.includes(provider.id)
                        ? 'border-rose-300 bg-rose-50'
                        : 'border-gray-200 hover:bg-gray-50'
                    }`}
                  >
                    <div className="flex items-center space-x-3">
                      <input
                        type="checkbox"
                        checked={selectedProviders.includes(provider.id)}
                        onChange={() => toggleProvider(provider.id)}
                        className="rounded border-gray-300 text-rose-500 focus:ring-rose-500"
                      />
                      <div className={`w-2 h-2 rounded-full ${provider.color}`} />
                      <span className="text-sm font-medium text-gray-900">{provider.name}</span>
                    </div>
                    <span className="text-xs text-gray-500">{provider.model}</span>
                  </label>
                ))}
              </div>
              {comparisonMode && selectedProviders.length > 1 && (
                <div className="mt-3 p-2 bg-purple-50 rounded-lg">
                  <p className="text-xs text-purple-700">
                    Comparison mode: Run task on {selectedProviders.length} providers simultaneously
                  </p>
                </div>
              )}
            </div>

            {/* Sample Tasks */}
            <div className="bg-white rounded-xl border border-gray-200 p-4">
              <div className="flex items-center justify-between mb-3">
                <h4 className="font-medium text-gray-900">Sample Tasks</h4>
                {comparisonMode && (
                  <button
                    onClick={() => setSandboxType(sandboxType === 'playwright_mcp' ? 'comparison' : 'playwright_mcp')}
                    className="text-xs text-rose-600 hover:text-rose-700"
                  >
                    {sandboxType === 'comparison' ? 'Browser Tasks' : 'Comparison Tasks'}
                  </button>
                )}
              </div>
              <div className="space-y-2">
                {SAMPLE_TASKS[sandboxType]?.map((sample, i) => (
                  <button
                    key={i}
                    onClick={() => setTask(sample.task)}
                    disabled={!canRun}
                    className="w-full text-left px-3 py-2 rounded-lg transition-colors border border-gray-200 hover:bg-gray-50 disabled:opacity-50"
                  >
                    <div className="font-medium text-sm text-gray-900">{sample.name}</div>
                    <div className="text-xs text-gray-500 mt-0.5">{sample.description}</div>
                  </button>
                ))}
              </div>
            </div>

            {/* Usage & Plan Info */}
            <div className="bg-gradient-to-br from-rose-50 to-purple-50 rounded-xl border border-rose-200 p-4">
              <h4 className="font-medium text-gray-900 mb-3">
                {usage?.plan === 'free' ? 'Free Tier' : `${usage?.plan?.toUpperCase() || 'FREE'} Plan`}
              </h4>

              {/* Usage Progress */}
              {usage && (
                <div className="mb-4">
                  <div className="flex justify-between text-sm mb-1">
                    <span className="text-gray-600">Agent Runs</span>
                    <span className={`font-medium ${usage.runs_remaining <= 1 ? 'text-rose-600' : 'text-gray-900'}`}>
                      {usage.runs_used} / {usage.runs_limit}
                    </span>
                  </div>
                  <div className="w-full bg-white rounded-full h-2 border border-rose-200">
                    <div
                      className={`h-2 rounded-full transition-all ${
                        usage.runs_remaining <= 1 ? 'bg-rose-500' : 'bg-emerald-500'
                      }`}
                      style={{ width: `${Math.min((usage.runs_used / usage.runs_limit) * 100, 100)}%` }}
                    />
                  </div>
                  {usage.runs_remaining <= 1 && (
                    <p className="text-xs text-rose-600 mt-1">
                      {usage.runs_remaining === 0 ? 'Limit reached!' : 'Almost at limit!'}
                    </p>
                  )}
                </div>
              )}

              <dl className="space-y-2 text-sm">
                <div className="flex justify-between">
                  <dt className="text-gray-500">Session Runs</dt>
                  <dd className="text-gray-900">{session?.runs_count || 0}/{session?.max_runs || FREE_TIER_LIMITS.max_runs}</dd>
                </div>
                <div className="flex justify-between">
                  <dt className="text-gray-500">Timeout</dt>
                  <dd className="text-gray-900">{FREE_TIER_LIMITS.timeout_seconds}s per task</dd>
                </div>
              </dl>

              {usage?.plan === 'free' && (
                <div className="mt-4 pt-4 border-t border-rose-200">
                  <button
                    onClick={() => setShowUpgradeModal(true)}
                    className="w-full text-center text-sm text-rose-600 hover:text-rose-700 font-medium"
                  >
                    Upgrade to PRO &#8594;
                  </button>
                </div>
              )}
            </div>

            {/* Run History */}
            {runs.length > 0 && (
              <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
                <div className="px-4 py-3 border-b border-gray-100">
                  <h4 className="font-medium text-gray-900">Run History</h4>
                </div>
                <div className="max-h-48 overflow-auto divide-y divide-gray-100">
                  {runs.slice().reverse().map((run, i) => (
                    <div
                      key={run.id || i}
                      className="px-4 py-3 hover:bg-gray-50 cursor-pointer"
                      onClick={() => setCurrentRun(run)}
                    >
                      <div className="flex items-center justify-between mb-1">
                        <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${getStatusColor(run.status || 'completed')}`}>
                          {run.status || 'completed'}
                        </span>
                        <span className="text-xs text-gray-400">
                          {run.tokens || 0} tokens
                        </span>
                      </div>
                      <p className="text-sm text-gray-600 truncate">
                        {run.task}
                      </p>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {/* New Session */}
            {session?.status === 'expired' && (
              <button
                onClick={createSession}
                className="w-full px-4 py-3 bg-rose-500 text-white rounded-lg hover:bg-rose-600 transition-colors"
              >
                Start New Session
              </button>
            )}
          </div>
        </div>
      </div>

      {/* Upgrade Modal */}
      {showUpgradeModal && (
        <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
          <div className="bg-white rounded-2xl max-w-4xl w-full overflow-hidden shadow-2xl max-h-[90vh] overflow-y-auto">
            {/* Header */}
            <div className="bg-gradient-to-r from-rose-500 to-purple-600 px-6 py-6 text-white text-center">
              <h2 className="text-2xl font-bold mb-1">Upgrade Your Plan</h2>
              <p className="text-rose-100 text-sm">
                You've used {usage?.runs_used || 0} of {usage?.runs_limit || 25} trial runs. Choose a plan to continue.
              </p>
            </div>

            {/* Pricing Grid */}
            <div className="p-6">
              <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                {/* Free Tier */}
                <div className="border border-gray-200 rounded-xl p-5">
                  <div className="text-center mb-4">
                    <h3 className="font-semibold text-gray-900">Free</h3>
                    <div className="mt-2">
                      <span className="text-3xl font-bold text-gray-900">$0</span>
                      <span className="text-gray-500">/mo</span>
                    </div>
                  </div>
                  <ul className="space-y-2 text-sm text-gray-600 mb-4">
                    <li className="flex items-start">
                      <span className="text-gray-400 mr-2">-</span>
                      25 trial runs/month
                    </li>
                    <li className="flex items-start">
                      <span className="text-gray-400 mr-2">-</span>
                      Community support
                    </li>
                    <li className="flex items-start">
                      <span className="text-gray-400 mr-2">-</span>
                      Basic features
                    </li>
                  </ul>
                  <button
                    disabled
                    className="w-full py-2 px-4 border border-gray-300 text-gray-400 rounded-lg text-sm cursor-not-allowed"
                  >
                    Current Plan
                  </button>
                </div>

                {/* Pro Tier - Highlighted */}
                <div className="border-2 border-rose-500 rounded-xl p-5 relative bg-rose-50">
                  <div className="absolute -top-3 left-1/2 transform -translate-x-1/2">
                    <span className="bg-rose-500 text-white text-xs font-semibold px-3 py-1 rounded-full">
                      RECOMMENDED
                    </span>
                  </div>
                  <div className="text-center mb-4 mt-2">
                    <h3 className="font-semibold text-gray-900">Pro</h3>
                    <div className="mt-2">
                      <span className="text-3xl font-bold text-gray-900">$99</span>
                      <span className="text-gray-500">/mo</span>
                    </div>
                    <p className="text-xs text-gray-500 mt-1">or $995/year (save 16%)</p>
                  </div>
                  <ul className="space-y-2 text-sm text-gray-700 mb-4">
                    <li className="flex items-start">
                      <span className="text-green-500 mr-2">&#10003;</span>
                      10,000 agent runs/month
                    </li>
                    <li className="flex items-start">
                      <span className="text-green-500 mr-2">&#10003;</span>
                      Advanced cost tracking
                    </li>
                    <li className="flex items-start">
                      <span className="text-green-500 mr-2">&#10003;</span>
                      25K traces/month
                    </li>
                    <li className="flex items-start">
                      <span className="text-green-500 mr-2">&#10003;</span>
                      Priority email support
                    </li>
                  </ul>
                  <button
                    onClick={() => handleUpgrade('monthly')}
                    disabled={isCheckingOut}
                    className="w-full py-2 px-4 bg-rose-500 text-white rounded-lg text-sm font-semibold hover:bg-rose-600 transition-colors disabled:opacity-50"
                  >
                    {isCheckingOut ? 'Loading...' : 'Upgrade to Pro'}
                  </button>
                </div>

                {/* Enterprise Tier */}
                <div className="border border-gray-200 rounded-xl p-5">
                  <div className="text-center mb-4">
                    <h3 className="font-semibold text-gray-900">Enterprise</h3>
                    <div className="mt-2">
                      <span className="text-3xl font-bold text-gray-900">$269</span>
                      <span className="text-gray-500">/mo</span>
                    </div>
                    <p className="text-xs text-gray-500 mt-1">or $2,690/year (save 16%)</p>
                  </div>
                  <ul className="space-y-2 text-sm text-gray-600 mb-4">
                    <li className="flex items-start">
                      <span className="text-green-500 mr-2">&#10003;</span>
                      Unlimited runs
                    </li>
                    <li className="flex items-start">
                      <span className="text-green-500 mr-2">&#10003;</span>
                      500K traces/month
                    </li>
                    <li className="flex items-start">
                      <span className="text-green-500 mr-2">&#10003;</span>
                      SSO & SOC2/HIPAA
                    </li>
                    <li className="flex items-start">
                      <span className="text-green-500 mr-2">&#10003;</span>
                      Dedicated support
                    </li>
                  </ul>
                  <a
                    href="mailto:sales@activeagents.ai"
                    className="block w-full py-2 px-4 border border-gray-300 text-gray-700 rounded-lg text-sm font-semibold text-center hover:bg-gray-50 transition-colors"
                  >
                    Contact Sales
                  </a>
                </div>
              </div>
            </div>

            {/* Footer */}
            <div className="px-6 py-4 bg-gray-50 border-t border-gray-100 flex justify-center">
              <button
                onClick={() => setShowUpgradeModal(false)}
                className="text-gray-500 hover:text-gray-700 text-sm"
              >
                Maybe later
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
