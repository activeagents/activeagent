import React, { useState, useEffect, useRef } from 'react';
import AgentAvatar from '../AgentAvatar';
import { TYPOGRAPHY } from '../../utils/designTokens';
import { startCheckout } from '../../utils/checkout';
import { roleBubble, streamPreStyle } from './InteractionStream';

// Feed event kinds mapped onto the shared stream chip palette so streamed
// run output matches the Interactions/Traces visual language.
const EVENT_BUBBLES = {
  llm: { role: 'assistant', label: 'LLM' },
  tool: { role: 'tool', label: 'Tool' },
  agent: { role: 'developer', label: 'Agent' },
  mcp: { role: 'system', label: 'MCP' },
};

const eventBubble = (kind) => {
  const mapping = EVENT_BUBBLES[kind] || { role: kind, label: kind };
  return { ...roleBubble(mapping.role, false), label: mapping.label };
};

export default function AgentRunner({ agent, onBack }) {
  const [prompt, setPrompt] = useState('');
  // Named action to invoke; agents always have the default #ask, plus any
  // configured action prompts (Instructions tab).
  const actionNames = ['ask', ...(agent.action_prompts || []).map(ap => ap.name).filter(Boolean)];
  const [actionName, setActionName] = useState('ask');
  const [runs, setRuns] = useState([]);
  const [isRunning, setIsRunning] = useState(false);
  const [currentRun, setCurrentRun] = useState(null);
  const [limitUsage, setLimitUsage] = useState(null);
  const [expandedEvents, setExpandedEvents] = useState({}); // eid -> bool
  const [isUpgrading, setIsUpgrading] = useState(false);
  const [upgradeError, setUpgradeError] = useState(null);
  const outputRef = useRef(null);

  useEffect(() => {
    loadRuns();
  }, [agent.id]);

  useEffect(() => {
    // Auto-scroll to bottom when new output arrives
    if (outputRef.current) {
      outputRef.current.scrollTop = outputRef.current.scrollHeight;
    }
  }, [currentRun?.output]);

  const loadRuns = async () => {
    try {
      const response = await fetch(`/api/agents/${agent.id}/runs?per_page=10`);
      const data = await response.json();
      setRuns(data.runs);
    } catch (error) {
      console.error('Failed to load runs:', error);
    }
  };

  // Kick off an async run, then poll the run endpoint so the activity feed
  // streams pending llm/tool/agent events while the run executes.
  const POLL_INTERVAL_MS = 1200;
  const POLL_TIMEOUT_MS = 10 * 60 * 1000;

  const handleRun = async () => {
    if (!prompt.trim() || isRunning) return;

    setIsRunning(true);
    setCurrentRun({
      status: 'pending',
      input_prompt: prompt,
      output: '',
      logs: [],
      started_at: new Date().toISOString()
    });

    try {
      const response = await fetch(`/api/agents/${agent.id}/execute`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt: prompt, action_name: actionName })
      });

      const data = await response.json();

      // Plan limit reached (402) — show the upgrade prompt
      if (response.status === 402 && data.upgrade_required) {
        setLimitUsage(data.usage);
        setCurrentRun(prev => ({
          ...prev,
          status: 'failed',
          error_message: data.message || 'Plan limit reached'
        }));
        return;
      }

      if (!response.ok) {
        throw new Error(data.error || 'Run failed');
      }

      const runId = data.run.id;
      const startedPolling = Date.now();

      const poll = async () => {
        try {
          const runResponse = await fetch(`/api/runs/${runId}`);
          if (runResponse.ok) {
            const runData = await runResponse.json();
            setCurrentRun(runData.run);
            if (!['pending', 'running'].includes(runData.run.status)) {
              setIsRunning(false);
              loadRuns();
              return;
            }
          }
        } catch {
          // transient poll failure — keep trying until timeout
        }
        if (Date.now() - startedPolling < POLL_TIMEOUT_MS) {
          setTimeout(poll, POLL_INTERVAL_MS);
        } else {
          setIsRunning(false);
        }
      };
      poll();
    } catch (error) {
      setCurrentRun(prev => ({
        ...prev,
        status: 'failed',
        error_message: error.message
      }));
      setIsRunning(false);
    }
  };

  // Pair started/done progress events by eid for the live activity feed.
  // The started event's detail is the call's input (tool arguments); the
  // finishing event's detail is its output (result preview or error).
  const activityFeed = (run) => {
    const byEid = new Map();
    (run?.logs || []).filter(entry => entry.eid).forEach(event => {
      const entry = byEid.get(event.eid) || { eid: event.eid };
      if (event.status === 'started') {
        Object.assign(entry, event, { input: event.detail, output: entry.output });
      } else {
        Object.assign(entry, event, { input: entry.input, output: event.detail });
      }
      byEid.set(event.eid, entry);
    });
    return [...byEid.values()];
  };

  const prettyEventJson = (value) => {
    if (!value) return null;
    try {
      return JSON.stringify(JSON.parse(value), null, 2);
    } catch {
      return value;
    }
  };


  const handleKeyDown = (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      handleRun();
    }
  };

  const getStatusColor = (status) => {
    switch (status) {
      case 'complete': return 'text-green-600 bg-green-100';
      case 'failed': return 'text-red-600 bg-red-100';
      case 'running': return 'text-blue-600 bg-blue-100';
      case 'pending': return 'text-yellow-600 bg-yellow-100';
      default: return 'text-gray-600 bg-gray-100';
    }
  };

  const formatDuration = (ms) => {
    if (!ms) return '-';
    if (ms < 1000) return `${ms}ms`;
    return `${(ms / 1000).toFixed(2)}s`;
  };

  const handleUpgrade = async () => {
    setIsUpgrading(true);
    setUpgradeError(null);
    try {
      await startCheckout({ planSlug: 'pro' });
    } catch (err) {
      setUpgradeError(err.message);
      setIsUpgrading(false);
    }
  };

  return (
    <div className="grid grid-cols-3 gap-6 h-full">
      {/* Main Runner Interface */}
      <div className="col-span-2 flex flex-col space-y-4">
        {/* Plan limit banner */}
        {limitUsage && (
          <div className="bg-amber-50 border border-amber-200 rounded-xl p-4 flex items-center justify-between gap-4">
            <div>
              <p className="font-medium text-amber-900">Monthly run limit reached</p>
              <p className="text-sm text-amber-700 mt-0.5">
                You've used {limitUsage.runs_used} of {limitUsage.runs_limit} runs on the{' '}
                {limitUsage.plan || 'free'} plan. Upgrade to keep running agents.
              </p>
              {upgradeError && <p className="text-sm text-red-600 mt-1">{upgradeError}</p>}
            </div>
            <div className="flex items-center gap-2 flex-shrink-0">
              <a href="/pricing" className="px-4 py-2 text-sm text-amber-800 hover:text-amber-900">
                See plans
              </a>
              <button
                onClick={handleUpgrade}
                disabled={isUpgrading}
                className="px-4 py-2 text-sm bg-amber-500 text-white rounded-lg hover:bg-amber-600 transition-colors disabled:opacity-50"
              >
                {isUpgrading ? 'Redirecting…' : 'Upgrade to Pro'}
              </button>
            </div>
          </div>
        )}

        {/* Input */}
        <div className="bg-white rounded-xl border border-gray-200 p-4">
          <div className="flex items-start space-x-4">
            <div className="flex-shrink-0">
              <AgentAvatar size={50} />
            </div>
            <div className="flex-1">
              <textarea
                value={prompt}
                onChange={(e) => setPrompt(e.target.value)}
                onKeyDown={handleKeyDown}
                placeholder="Enter your prompt here... (Cmd+Enter to run)"
                rows={4}
                disabled={isRunning}
                className="w-full px-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500 focus:border-transparent resize-none"
              />
              <div className="flex items-center justify-between mt-3">
                <div className="flex items-center gap-3">
                  {actionNames.length > 1 && (
                    <select
                      value={actionName}
                      onChange={(e) => setActionName(e.target.value)}
                      disabled={isRunning}
                      className="px-2 py-1 border border-gray-300 rounded-lg text-sm font-mono text-gray-700 focus:ring-2 focus:ring-red-500"
                      title="Agent action to invoke"
                    >
                      {actionNames.map(name => (
                        <option key={name} value={name}>#{name}</option>
                      ))}
                    </select>
                  )}
                  <span className="text-xs text-gray-400">
                    Press <kbd className="px-1.5 py-0.5 bg-gray-100 rounded text-gray-600">⌘</kbd> + <kbd className="px-1.5 py-0.5 bg-gray-100 rounded text-gray-600">Enter</kbd> to run
                  </span>
                </div>
                <button
                  onClick={handleRun}
                  disabled={!prompt.trim() || isRunning}
                  className={`flex items-center space-x-2 px-6 py-2 rounded-lg transition-colors ${
                    prompt.trim() && !isRunning
                      ? 'bg-emerald-500 text-white hover:bg-emerald-600'
                      : 'bg-gray-200 text-gray-400 cursor-not-allowed'
                  }`}
                >
                  {isRunning ? (
                    <>
                      <span className="animate-spin" style={{ fontFamily: TYPOGRAPHY.mono }}>{'[~]'}</span>
                      <span>Running...</span>
                    </>
                  ) : (
                    <>
                      <span style={{ fontFamily: TYPOGRAPHY.mono }}>{'[>]'}</span>
                      <span>Run</span>
                    </>
                  )}
                </button>
              </div>
            </div>
          </div>
        </div>

        {/* Output */}
        <div className="flex-1 bg-white rounded-xl border border-gray-200 flex flex-col overflow-hidden">
          <div className="px-4 py-3 border-b border-gray-200 flex items-center justify-between">
            <h3 className="font-medium text-gray-900">Output</h3>
            {currentRun && (
              <div className="flex items-center space-x-3 text-sm">
                <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${getStatusColor(currentRun.status)}`}>
                  {currentRun.status}
                </span>
                {currentRun.output_metadata?.model && (
                  <span className="px-2 py-0.5 rounded bg-indigo-50 text-indigo-700 text-xs font-mono" title="Model that generated this run">
                    {currentRun.output_metadata.provider}/{currentRun.output_metadata.model}
                  </span>
                )}
                {currentRun.duration_ms && (
                  <span className="text-gray-400">{formatDuration(currentRun.duration_ms)}</span>
                )}
                {currentRun.total_tokens && (
                  <span className="text-gray-400">{currentRun.total_tokens} tokens</span>
                )}
                {currentRun.trace_id && (
                  <a
                    href={`/dashboard/traces?trace=${currentRun.trace_id}`}
                    className="text-gray-400 hover:text-red-500 font-mono text-xs"
                    title={`${currentRun.trace_id} — open in Traces`}
                  >
                    trace:{currentRun.trace_id.slice(0, 8)} →
                  </a>
                )}
              </div>
            )}
          </div>

          <div
            ref={outputRef}
            className="flex-1 p-4 overflow-auto bg-gray-50 font-mono text-sm"
          >
            {currentRun ? (
              <>
                {/* Live activity feed — same chip/expansion design as the
                    Interactions stream, one row per llm/tool/agent call.
                    Click a row to inspect the call's input and output. */}
                {activityFeed(currentRun).length > 0 && (
                  <div className="mb-4 space-y-2">
                    {activityFeed(currentRun).map(event => {
                      const isExpanded = !!expandedEvents[event.eid];
                      const expandable = Boolean(event.input || event.output);
                      const bubble = eventBubble(event.kind);
                      const preStyle = streamPreStyle(false);
                      return (
                        <div key={event.eid}>
                          <div
                            className={`flex gap-3 items-start rounded-lg -mx-2 px-2 py-1 ${expandable ? 'cursor-pointer hover:bg-black/5' : ''}`}
                            onClick={expandable ? () => setExpandedEvents(prev => ({ ...prev, [event.eid]: !prev[event.eid] })) : undefined}
                            title={expandable ? 'Click to inspect input/output' : undefined}
                            style={isExpanded ? { background: 'rgba(0,0,0,0.03)' } : {}}
                          >
                            <span
                              className="px-2 py-0.5 rounded text-xs font-medium flex-shrink-0 mt-0.5"
                              style={{ background: bubble.background, color: bubble.color, minWidth: '72px', textAlign: 'center' }}
                            >
                              {bubble.label}
                            </span>
                            <div className="min-w-0 flex-1">
                              <div className="text-sm break-words text-gray-800">
                                {event.label}
                                {event.output && !isExpanded && (
                                  <span className="text-gray-400"> “{event.output.slice(0, 160)}{event.output.length > 160 ? '…' : ''}”</span>
                                )}
                              </div>
                              <div className="text-xs mt-0.5 font-mono flex items-center gap-2 flex-wrap text-gray-400">
                                {event.status === 'started' ? (
                                  <span className="text-blue-500 animate-pulse">running…</span>
                                ) : (
                                  <span className={event.status === 'error' ? 'text-red-500' : ''}>
                                    {event.status === 'error' ? 'failed' : '✓'}
                                    {event.duration_ms != null && ` ${formatDuration(event.duration_ms)}`}
                                  </span>
                                )}
                                {event.at && <span>{new Date(event.at).toLocaleTimeString()}</span>}
                              </div>
                            </div>
                            {expandable && (
                              <svg
                                className={`w-3.5 h-3.5 mt-1 flex-shrink-0 transition-transform ${isExpanded ? 'rotate-180' : ''} text-gray-400`}
                                fill="none" stroke="currentColor" viewBox="0 0 24 24"
                              >
                                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
                              </svg>
                            )}
                          </div>

                          {isExpanded && (
                            <div
                              className="ml-3 mt-1 mb-2 pl-4 space-y-2 border-l-2"
                              style={{ borderColor: bubble.color + '55' }}
                            >
                              {event.input && (
                                <div>
                                  <div className="text-xs uppercase tracking-wide mb-1 text-gray-400">Input</div>
                                  <pre style={{ ...preStyle, whiteSpace: 'pre-wrap', maxHeight: '160px', overflowY: 'auto' }}>{prettyEventJson(event.input)}</pre>
                                </div>
                              )}
                              {event.output && (
                                <div>
                                  <div className="text-xs uppercase tracking-wide mb-1 text-gray-400">
                                    {event.status === 'error' ? 'Error' : 'Result'}
                                  </div>
                                  <pre
                                    style={{
                                      ...preStyle,
                                      whiteSpace: 'pre-wrap',
                                      maxHeight: '224px',
                                      overflowY: 'auto',
                                      ...(event.status === 'error' ? { background: '#fef2f2', color: '#b91c1c' } : {})
                                    }}
                                  >{prettyEventJson(event.output)}</pre>
                                </div>
                              )}
                            </div>
                          )}
                        </div>
                      );
                    })}
                  </div>
                )}

                {['pending', 'running'].includes(currentRun.status) ? (
                  <div className="flex items-center space-x-2 text-gray-500">
                    <span className="animate-pulse">●</span>
                    <span>{activityFeed(currentRun).length > 0 ? 'Working…' : 'Starting run…'}</span>
                  </div>
                ) : currentRun.error_message ? (
                  <div className="text-red-600">
                    <div className="font-semibold mb-2">Error:</div>
                    <pre className="whitespace-pre-wrap">{currentRun.error_message}</pre>
                  </div>
                ) : (
                  <pre className="whitespace-pre-wrap text-gray-800">{currentRun.output || 'No output'}</pre>
                )}
              </>
            ) : (
              <div className="text-gray-400 text-center py-12">
                Enter a prompt and click Run to test your agent
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Sidebar */}
      <div className="space-y-4">
        {/* Agent Info */}
        <div className="bg-white rounded-xl border border-gray-200 p-4">
          <div className="flex items-center space-x-3 mb-4">
            <AgentAvatar size={60} />
            <div>
              <h3 className="font-semibold text-gray-900">{agent.name}</h3>
              <p className="text-sm text-gray-500">{agent.provider} / {agent.model}</p>
            </div>
          </div>

          <button
            onClick={onBack}
            className="w-full px-4 py-2 border border-gray-300 rounded-lg text-gray-700 hover:bg-gray-50 transition-colors"
          >
            ← Back to Editor
          </button>
        </div>

        {/* Configuration Preview */}
        <div className="bg-white rounded-xl border border-gray-200 p-4">
          <h4 className="font-medium text-gray-900 mb-3">Configuration</h4>
          <dl className="space-y-2 text-sm">
            <div className="flex justify-between">
              <dt className="text-gray-500">Temperature</dt>
              <dd className="text-gray-900">{agent.modelConfig?.temperature || agent.model_config?.temperature || 0.7}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-gray-500">Tools</dt>
              <dd className="text-gray-900">{agent.tools?.length || 0}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-gray-500">Status</dt>
              <dd className={`px-2 py-0.5 rounded text-xs ${
                agent.status === 'active' ? 'bg-green-100 text-green-700' : 'bg-gray-100 text-gray-600'
              }`}>
                {agent.status}
              </dd>
            </div>
          </dl>

          {agent.instructions && (
            <div className="mt-3 pt-3 border-t border-gray-100">
              <div className="text-xs text-gray-500 mb-1.5">System Instructions</div>
              <p className="text-xs text-gray-700 whitespace-pre-wrap max-h-44 overflow-y-auto font-mono leading-relaxed">
                {agent.instructions}
              </p>
            </div>
          )}
        </div>

        {/* Recent Runs */}
        <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
          <div className="px-4 py-3 border-b border-gray-100">
            <h4 className="font-medium text-gray-900">Recent Runs</h4>
          </div>

          <div className="max-h-64 overflow-auto">
            {runs.length > 0 ? (
              <div className="divide-y divide-gray-100">
                {runs.map(run => (
                  <div
                    key={run.id}
                    className="px-4 py-3 hover:bg-gray-50 cursor-pointer"
                    onClick={() => setCurrentRun(run)}
                  >
                    <div className="flex items-center justify-between mb-1">
                      <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${getStatusColor(run.status)}`}>
                        {run.status}
                      </span>
                      <span className="text-xs text-gray-400">
                        {formatDuration(run.duration_ms)}
                      </span>
                    </div>
                    <p className="text-sm text-gray-600 truncate">
                      {run.input_preview || run.input_prompt?.substring(0, 50)}
                    </p>
                    <p className="text-xs text-gray-400 mt-1 flex items-center gap-2 flex-wrap">
                      {run.model && (
                        <span className="px-1.5 py-0.5 rounded bg-indigo-50 text-indigo-700 font-mono">{run.model}</span>
                      )}
                      <span>{new Date(run.created_at).toLocaleString()}</span>
                    </p>
                  </div>
                ))}
              </div>
            ) : (
              <div className="px-4 py-8 text-center text-gray-400 text-sm">
                No runs yet
              </div>
            )}
          </div>
        </div>

        {/* Example Prompts */}
        <div className="bg-white rounded-xl border border-gray-200 p-4">
          <h4 className="font-medium text-gray-900 mb-3">Example Prompts</h4>
          <div className="space-y-2">
            {[
              "Hello, what can you help me with?",
              "List the files in the current directory",
              "Explain how this code works"
            ].map((example, i) => (
              <button
                key={i}
                onClick={() => setPrompt(example)}
                className="w-full text-left px-3 py-2 text-sm text-gray-600 hover:bg-gray-50 rounded-lg transition-colors border border-gray-200"
              >
                {example}
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
