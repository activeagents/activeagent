import React, { useState, useEffect, useCallback, useRef } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { TYPOGRAPHY } from '../../utils/designTokens';

// Playwright-style action replay mode
const REPLAY_MODE = {
  SCREENSHOT: 'screenshot',  // Show stored screenshots (if available)
  IFRAME: 'iframe',          // Live iframe replay with action visualization
};

const ACTION_ICONS = {
  navigate: '[->]',
  click: '[*]',
  type: '[T]',
  form_fill: '[F]',
  key_press: '[K]',
  snapshot: '[S]',
  hover: '[~]',
  select: '[v]',
  file_upload: '[^]',
  dialog: '[!]',
  evaluate: '[js]',
  wait: '[..]',
  scroll: '[|]',
  drag: '[<>]',
};

const ACTION_COLORS = {
  navigate: '#3b82f6',
  click: '#ef4444',
  type: '#10b981',
  form_fill: '#8b5cf6',
  key_press: '#f59e0b',
  snapshot: '#06b6d4',
  hover: '#ec4899',
  select: '#6366f1',
  file_upload: '#14b8a6',
  dialog: '#f97316',
  evaluate: '#a855f7',
  wait: '#94a3b8',
  scroll: '#64748b',
  drag: '#ea580c',
};

// CSS keyframes for animations
const rippleKeyframes = `
  @keyframes ripple {
    0% { transform: translate(-50%, -50%) scale(0.5); opacity: 1; }
    100% { transform: translate(-50%, -50%) scale(2); opacity: 0; }
  }
  @keyframes typing-cursor {
    0%, 100% { opacity: 1; }
    50% { opacity: 0; }
  }
  @keyframes pulse {
    0%, 100% { opacity: 1; transform: scale(1); }
    50% { opacity: 0.5; transform: scale(1.2); }
  }
`;

export default function SessionReplayView({ recordingId: initialRecordingId, onHandoff, onClose }) {
  const { darkMode } = useTheme();
  const [recordings, setRecordings] = useState([]);
  const [selectedRecordingId, setSelectedRecordingId] = useState(initialRecordingId);
  const [recording, setRecording] = useState(null);
  const [actions, setActions] = useState([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState(null);

  // Playback state
  const [isPlaying, setIsPlaying] = useState(false);
  const [currentActionIndex, setCurrentActionIndex] = useState(0);
  const [playbackSpeed, setPlaybackSpeed] = useState(1);
  const [currentScreenshot, setCurrentScreenshot] = useState(null);

  // Timeline ref for scrubbing
  const timelineRef = useRef(null);
  const playbackTimer = useRef(null);
  const iframeRef = useRef(null);

  // Replay mode - use iframe for sessions without screenshots
  const [replayMode, setReplayMode] = useState(REPLAY_MODE.IFRAME);
  const [cursorPosition, setCursorPosition] = useState({ x: 0, y: 0, visible: false });
  const [highlightedElement, setHighlightedElement] = useState(null);

  // Load list of recordings on mount
  useEffect(() => {
    loadRecordingsList();
  }, []);

  // Load specific recording when selected
  useEffect(() => {
    if (selectedRecordingId) {
      loadRecording(selectedRecordingId);
    }
  }, [selectedRecordingId]);

  const loadRecordingsList = async () => {
    try {
      const response = await fetch('/api/session_recordings');
      if (response.ok) {
        const data = await response.json();
        setRecordings(data.recordings || []);
        // Auto-select the first recording if none selected
        if (!selectedRecordingId && data.recordings?.length > 0) {
          setSelectedRecordingId(data.recordings[0].id);
        }
      }
    } catch (err) {
      console.error('Failed to load recordings list:', err);
    }
  };

  // Handle playback
  useEffect(() => {
    if (!isPlaying || actions.length === 0) {
      if (playbackTimer.current) {
        clearTimeout(playbackTimer.current);
      }
      return;
    }

    const currentAction = actions[currentActionIndex];
    const nextAction = actions[currentActionIndex + 1];

    if (!nextAction) {
      // End of recording
      setIsPlaying(false);
      return;
    }

    const delay = (nextAction.timestamp_ms - currentAction.timestamp_ms) / playbackSpeed;

    playbackTimer.current = setTimeout(() => {
      setCurrentActionIndex(prev => prev + 1);
    }, Math.max(delay, 50)); // Minimum 50ms between actions

    return () => {
      if (playbackTimer.current) {
        clearTimeout(playbackTimer.current);
      }
    };
  }, [isPlaying, currentActionIndex, actions, playbackSpeed]);

  // Update screenshot when action changes, or simulate action in iframe mode
  useEffect(() => {
    const action = actions[currentActionIndex];
    if (action?.screenshot_url) {
      setCurrentScreenshot(action.screenshot_url);
      setReplayMode(REPLAY_MODE.SCREENSHOT);
    } else if (replayMode === REPLAY_MODE.IFRAME) {
      // Simulate the action visually in the iframe
      simulateActionInIframe(action);
    }
  }, [currentActionIndex, actions, replayMode]);

  // Simulate Playwright-style action visualization in the iframe
  const simulateActionInIframe = useCallback((action) => {
    if (!action || !iframeRef.current) return;

    const iframe = iframeRef.current;

    try {
      // Get the page URL from recording metadata or use the landing page
      const pageUrl = recording?.metadata?.page_url || '/';

      // Ensure iframe is loaded with the right page
      if (iframe.src !== pageUrl && !iframe.src.includes(pageUrl)) {
        // Will be set on first load
      }

      // Simulate cursor movement and element highlighting based on action type
      switch (action.action_type) {
        case 'navigate':
          setCursorPosition({ x: 50, y: 50, visible: true });
          setHighlightedElement(null);
          break;

        case 'click':
        case 'focus':
          // Position cursor near the selector location
          setCursorPosition({ x: 200, y: 300, visible: true });
          setHighlightedElement(action.selector);
          // Try to highlight element in iframe
          highlightElementInIframe(action.selector);
          break;

        case 'type':
          setCursorPosition({ x: 200, y: 300, visible: true });
          setHighlightedElement(action.selector);
          // Simulate typing animation
          simulateTypingInIframe(action.selector, action.value);
          break;

        case 'submit':
          setCursorPosition({ x: 250, y: 400, visible: true });
          setHighlightedElement(action.selector);
          break;

        case 'scroll':
          setCursorPosition({ x: 300, y: 200, visible: true });
          setHighlightedElement(null);
          break;

        case 'handoff':
          setCursorPosition({ x: 0, y: 0, visible: false });
          setHighlightedElement(null);
          break;

        default:
          setCursorPosition({ x: 150, y: 250, visible: true });
          setHighlightedElement(action.selector);
      }
    } catch (err) {
      console.log('Could not simulate action in iframe:', err);
    }
  }, [recording]);

  // Try to highlight an element in the iframe
  const highlightElementInIframe = (selector) => {
    if (!selector || !iframeRef.current) return;

    try {
      const iframeDoc = iframeRef.current.contentDocument || iframeRef.current.contentWindow?.document;
      if (!iframeDoc) return;

      // Remove previous highlights
      iframeDoc.querySelectorAll('.session-replay-highlight').forEach(el => {
        el.classList.remove('session-replay-highlight');
        el.style.outline = '';
      });

      // Add highlight to target element
      const targetEl = iframeDoc.querySelector(selector);
      if (targetEl) {
        targetEl.classList.add('session-replay-highlight');
        targetEl.style.outline = '3px solid #ef4444';
        targetEl.style.outlineOffset = '2px';

        // Scroll element into view
        targetEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
      }
    } catch (err) {
      // Cross-origin access may fail - that's ok
    }
  };

  // Simulate typing in the iframe
  const simulateTypingInIframe = (selector, value) => {
    if (!selector || !value || !iframeRef.current) return;

    try {
      const iframeDoc = iframeRef.current.contentDocument || iframeRef.current.contentWindow?.document;
      if (!iframeDoc) return;

      const input = iframeDoc.querySelector(selector);
      if (input && (input.tagName === 'INPUT' || input.tagName === 'TEXTAREA')) {
        // Animate typing effect
        let charIndex = 0;
        const typeInterval = setInterval(() => {
          if (charIndex < value.length) {
            input.value = value.substring(0, charIndex + 1);
            charIndex++;
          } else {
            clearInterval(typeInterval);
          }
        }, 50);
      }
    } catch (err) {
      // Cross-origin access may fail
    }
  };

  const loadRecording = async (recordingId) => {
    setIsLoading(true);
    setError(null);

    try {
      // If no recordingId, try to load demo recording
      const url = recordingId
        ? `/api/session_recordings/${recordingId}`
        : '/api/session_recordings/demo';

      const response = await fetch(url);
      if (!response.ok) throw new Error('Failed to load recording');

      const data = await response.json();
      setRecording(data.recording);
      setCurrentActionIndex(0);
      setIsPlaying(false);

      // Load actions separately if we have a recording
      if (data.recording?.id) {
        const actionsResponse = await fetch(`/api/session_recordings/${data.recording.id}/actions`);
        if (actionsResponse.ok) {
          const actionsData = await actionsResponse.json();
          setActions(actionsData.actions || data.recording.timeline || []);
        } else {
          setActions(data.recording.timeline || []);
        }
      }
    } catch (err) {
      setError(err.message);
    } finally {
      setIsLoading(false);
    }
  };

  const handlePlayPause = () => {
    if (currentActionIndex >= actions.length - 1) {
      // Reset to beginning if at end
      setCurrentActionIndex(0);
    }
    setIsPlaying(!isPlaying);
  };

  const handleStepForward = () => {
    setIsPlaying(false);
    setCurrentActionIndex(prev => Math.min(prev + 1, actions.length - 1));
  };

  const handleStepBackward = () => {
    setIsPlaying(false);
    setCurrentActionIndex(prev => Math.max(prev - 1, 0));
  };

  const handleTimelineClick = (e) => {
    if (!timelineRef.current || actions.length === 0) return;

    const rect = timelineRef.current.getBoundingClientRect();
    const clickX = e.clientX - rect.left;
    const percentage = clickX / rect.width;
    const targetTime = percentage * (recording?.duration_ms || actions[actions.length - 1]?.timestamp_ms || 0);

    // Find closest action to clicked time
    const closestIndex = actions.findIndex((action, idx) => {
      const nextAction = actions[idx + 1];
      return !nextAction || targetTime < nextAction.timestamp_ms;
    });

    setCurrentActionIndex(Math.max(0, closestIndex));
    setIsPlaying(false);
  };

  const handleHandoff = async () => {
    if (!recording?.id) return;

    try {
      const response = await fetch(`/api/session_recordings/${recording.id}/handoff`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
      });

      if (!response.ok) throw new Error('Handoff not available');

      const data = await response.json();
      if (onHandoff) {
        onHandoff(data);
      }
    } catch (err) {
      setError(err.message);
    }
  };

  const formatTime = (ms) => {
    if (!ms) return '0:00';
    const seconds = Math.floor(ms / 1000);
    const minutes = Math.floor(seconds / 60);
    const remainingSeconds = seconds % 60;
    return `${minutes}:${remainingSeconds.toString().padStart(2, '0')}`;
  };

  const currentAction = actions[currentActionIndex];
  const progress = recording?.duration_ms
    ? (currentAction?.timestamp_ms || 0) / recording.duration_ms * 100
    : 0;

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-red-500"></div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="text-red-500">{error}</div>
      </div>
    );
  }

  if (!recording) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="text-gray-500">No recording available</div>
      </div>
    );
  }

  // Shared styles for dark mode
  const containerStyle = darkMode ? {
    background: 'linear-gradient(180deg, #1a1a2e 0%, #16213e 100%)',
    borderRadius: '12px',
    overflow: 'hidden',
    minHeight: 'calc(100vh - 200px)',
  } : {};

  return (
    <div
      className={darkMode ? '' : 'bg-white rounded-xl border border-gray-200'}
      style={containerStyle}
    >
      {/* Inject keyframe animations */}
      <style dangerouslySetInnerHTML={{ __html: rippleKeyframes }} />
      {/* Header */}
      <div
        className={darkMode ? '' : 'border-b border-gray-200 p-4'}
        style={darkMode ? {
          padding: '16px 24px',
          borderBottom: '1px solid rgba(255,255,255,0.1)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
        } : { display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}
      >
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
            <h2
              className={darkMode ? '' : 'text-xl font-semibold text-gray-900'}
              style={darkMode ? { fontSize: '20px', fontWeight: '600', color: 'white', margin: 0 } : {}}
            >
              {recording.name || 'Session Replay'}
            </h2>
            {recordings.length > 1 && (
              <select
                value={selectedRecordingId || ''}
                onChange={(e) => setSelectedRecordingId(Number(e.target.value))}
                style={{
                  padding: '6px 12px',
                  borderRadius: '6px',
                  border: darkMode ? '1px solid rgba(255,255,255,0.2)' : '1px solid #d1d5db',
                  background: darkMode ? 'rgba(255,255,255,0.1)' : 'white',
                  color: darkMode ? 'white' : '#374151',
                  fontSize: '14px',
                  cursor: 'pointer',
                }}
              >
                {recordings.map(r => (
                  <option key={r.id} value={r.id}>
                    {r.name} ({new Date(r.created_at).toLocaleDateString()})
                  </option>
                ))}
              </select>
            )}
          </div>
          <p
            className={darkMode ? '' : 'text-sm text-gray-500 mt-1'}
            style={darkMode ? { fontSize: '14px', color: 'rgba(255,255,255,0.6)', marginTop: '4px' } : {}}
          >
            {recording.action_count} actions | {formatTime(recording.duration_ms)} duration
          </p>
        </div>

        <div className="flex items-center gap-3">
          {recording.handoff_state && (
            <button
              onClick={handleHandoff}
              className={darkMode
                ? ''
                : 'px-4 py-2 bg-gradient-to-r from-red-500 to-rose-500 text-white rounded-lg hover:from-red-600 hover:to-rose-600 font-medium'
              }
              style={darkMode ? {
                padding: '10px 20px',
                background: 'linear-gradient(90deg, #ef4444 0%, #f43f5e 100%)',
                color: 'white',
                borderRadius: '8px',
                border: 'none',
                fontWeight: '500',
                cursor: 'pointer',
                fontSize: '14px',
              } : {}}
            >
              Take Over Session
            </button>
          )}
          {onClose && (
            <button
              onClick={onClose}
              className={darkMode ? '' : 'text-gray-400 hover:text-gray-600'}
              style={darkMode ? { color: 'rgba(255,255,255,0.6)', background: 'none', border: 'none', cursor: 'pointer' } : {}}
            >
              <span style={{ fontSize: '20px' }}>x</span>
            </button>
          )}
        </div>
      </div>

      {/* Main Content */}
      <div
        className={darkMode ? '' : 'flex h-[500px]'}
        style={darkMode ? { display: 'flex', height: '500px' } : {}}
      >
        {/* Screenshot/Iframe Viewport */}
        <div
          className={darkMode ? '' : 'flex-1 bg-gray-100 flex items-center justify-center relative'}
          style={darkMode ? {
            flex: 1,
            background: 'rgba(0,0,0,0.3)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            position: 'relative',
            overflow: 'hidden',
          } : { overflow: 'hidden' }}
        >
          {replayMode === REPLAY_MODE.SCREENSHOT && currentScreenshot ? (
            <img
              src={currentScreenshot}
              alt="Session screenshot"
              className="max-w-full max-h-full object-contain"
            />
          ) : (
            /* Iframe Replay Mode - shows actual page with Playwright-style cursor */
            <div style={{
              width: '100%',
              height: '100%',
              position: 'relative',
              overflow: 'hidden',
            }}>
              {/* The iframe showing the page being replayed */}
              <iframe
                ref={iframeRef}
                src={recording?.metadata?.page_url || '/'}
                style={{
                  border: 'none',
                  transform: 'scale(0.75)',
                  transformOrigin: 'top left',
                  width: '133.33%',
                  height: '133.33%',
                  pointerEvents: 'none', // Prevent user interaction during replay
                }}
                sandbox="allow-same-origin allow-scripts"
              />

              {/* Playwright-style cursor overlay */}
              {cursorPosition.visible && (
                <div
                  style={{
                    position: 'absolute',
                    left: `${cursorPosition.x}px`,
                    top: `${cursorPosition.y}px`,
                    width: '24px',
                    height: '24px',
                    pointerEvents: 'none',
                    zIndex: 100,
                    transition: 'all 0.3s ease-out',
                  }}
                >
                  {/* Cursor icon */}
                  <svg
                    viewBox="0 0 24 24"
                    fill="none"
                    style={{ width: '100%', height: '100%' }}
                  >
                    <path
                      d="M4 4L12 20L14 14L20 12L4 4Z"
                      fill="#ef4444"
                      stroke="white"
                      strokeWidth="2"
                    />
                  </svg>
                  {/* Click ripple effect */}
                  {currentAction?.action_type === 'click' && (
                    <div
                      style={{
                        position: 'absolute',
                        top: '50%',
                        left: '50%',
                        transform: 'translate(-50%, -50%)',
                        width: '40px',
                        height: '40px',
                        borderRadius: '50%',
                        border: '3px solid #ef4444',
                        animation: 'ripple 0.6s ease-out',
                        opacity: 0,
                      }}
                    />
                  )}
                </div>
              )}

              {/* Highlighted element indicator */}
              {highlightedElement && (
                <div
                  style={{
                    position: 'absolute',
                    bottom: '16px',
                    left: '16px',
                    background: 'rgba(0,0,0,0.8)',
                    color: '#60a5fa',
                    padding: '8px 12px',
                    borderRadius: '6px',
                    fontSize: '12px',
                    fontFamily: TYPOGRAPHY.mono,
                    zIndex: 100,
                  }}
                >
                  {highlightedElement}
                </div>
              )}

              {/* Action being performed indicator */}
              {currentAction && (
                <div
                  style={{
                    position: 'absolute',
                    top: '60px',
                    left: '16px',
                    background: 'rgba(0,0,0,0.8)',
                    color: 'white',
                    padding: '8px 16px',
                    borderRadius: '6px',
                    fontSize: '13px',
                    display: 'flex',
                    alignItems: 'center',
                    gap: '8px',
                    zIndex: 100,
                  }}
                >
                  <span style={{ color: ACTION_COLORS[currentAction.action_type] || '#94a3b8', fontWeight: '600' }}>
                    {ACTION_ICONS[currentAction.action_type] || '[?]'}
                  </span>
                  <span>{currentAction.action_type}</span>
                  {currentAction.value && (
                    <span style={{ color: 'rgba(255,255,255,0.6)', maxWidth: '200px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      : {currentAction.value}
                    </span>
                  )}
                </div>
              )}
            </div>
          )}

          {/* Recording/Playback state indicator */}
          <div
            className={darkMode ? '' : 'absolute top-4 left-4 flex items-center gap-2 text-white px-3 py-1 rounded-full text-sm'}
            style={{
              position: 'absolute',
              top: '16px',
              left: '16px',
              display: 'flex',
              alignItems: 'center',
              gap: '8px',
              background: recording?.status === 'recording' ? '#ef4444' : isPlaying ? '#10b981' : '#6b7280',
              color: 'white',
              padding: '6px 12px',
              borderRadius: '999px',
              fontSize: '13px',
              fontWeight: '500',
            }}
          >
            {/* State-specific icon */}
            {recording?.status === 'recording' ? (
              // Recording state: pulsing red dot
              <span
                style={{
                  width: '8px',
                  height: '8px',
                  borderRadius: '50%',
                  background: 'white',
                  animation: 'pulse 1.5s ease-in-out infinite',
                }}
              />
            ) : isPlaying ? (
              // Playing state: play icon (triangle)
              <svg width="10" height="12" viewBox="0 0 10 12" fill="white">
                <path d="M0 0L10 6L0 12V0Z" />
              </svg>
            ) : (
              // Paused state: pause icon (two bars)
              <svg width="10" height="12" viewBox="0 0 10 12" fill="white">
                <rect x="0" y="0" width="3" height="12" />
                <rect x="7" y="0" width="3" height="12" />
              </svg>
            )}
            {/* State text */}
            {recording?.status === 'recording' ? 'REC' : isPlaying ? 'Playing' : 'Paused'}
          </div>

          {/* Cursor indicator */}
          {currentAction?.selector && (
            <div
              className={darkMode ? '' : 'absolute bottom-4 left-4 bg-black/75 text-white px-3 py-1 rounded text-sm font-mono'}
              style={darkMode ? {
                position: 'absolute',
                bottom: '16px',
                left: '16px',
                background: 'rgba(0,0,0,0.75)',
                color: 'white',
                padding: '6px 12px',
                borderRadius: '6px',
                fontSize: '13px',
                fontFamily: TYPOGRAPHY.mono,
              } : {}}
            >
              {currentAction.selector}
            </div>
          )}
        </div>

        {/* Action Sidebar */}
        <div
          className={darkMode ? '' : 'w-80 border-l border-gray-200 flex flex-col'}
          style={darkMode ? {
            width: '320px',
            borderLeft: '1px solid rgba(255,255,255,0.1)',
            display: 'flex',
            flexDirection: 'column',
          } : {}}
        >
          {/* Actions List */}
          <div
            className={darkMode ? '' : 'flex-1 overflow-auto'}
            style={darkMode ? { flex: 1, overflowY: 'auto' } : {}}
          >
            <div
              className={darkMode ? '' : 'p-3 border-b border-gray-100 font-medium text-sm text-gray-700'}
              style={darkMode ? {
                padding: '12px 16px',
                borderBottom: '1px solid rgba(255,255,255,0.1)',
                fontWeight: '500',
                fontSize: '14px',
                color: 'rgba(255,255,255,0.8)',
              } : {}}
            >
              Actions ({actions.length})
            </div>

            {actions.map((action, idx) => {
              const isActive = idx === currentActionIndex;
              const isPast = idx < currentActionIndex;
              const color = ACTION_COLORS[action.action_type] || '#94a3b8';

              return (
                <div
                  key={action.id || idx}
                  onClick={() => {
                    setCurrentActionIndex(idx);
                    setIsPlaying(false);
                  }}
                  className={darkMode ? '' : `px-4 py-3 cursor-pointer border-b border-gray-50 hover:bg-gray-50 ${isActive ? 'bg-red-50 border-l-2 border-l-red-500' : ''}`}
                  style={darkMode ? {
                    padding: '12px 16px',
                    cursor: 'pointer',
                    borderBottom: '1px solid rgba(255,255,255,0.05)',
                    background: isActive ? 'rgba(239, 68, 68, 0.15)' : 'transparent',
                    borderLeft: isActive ? '3px solid #ef4444' : '3px solid transparent',
                    opacity: isPast ? 0.6 : 1,
                  } : { opacity: isPast ? 0.6 : 1 }}
                >
                  <div className="flex items-center gap-2">
                    <span
                      style={{
                        color: color,
                        fontFamily: TYPOGRAPHY.mono,
                        fontSize: '12px',
                        fontWeight: '600',
                      }}
                    >
                      {ACTION_ICONS[action.action_type] || '[?]'}
                    </span>
                    <span
                      className={darkMode ? '' : 'text-sm font-medium text-gray-900'}
                      style={darkMode ? { fontSize: '14px', fontWeight: '500', color: 'white' } : {}}
                    >
                      {action.action_type}
                    </span>
                    <span
                      className={darkMode ? '' : 'text-xs text-gray-400 ml-auto'}
                      style={darkMode ? { fontSize: '12px', color: 'rgba(255,255,255,0.4)', marginLeft: 'auto' } : {}}
                    >
                      {formatTime(action.timestamp_ms)}
                    </span>
                  </div>
                  {action.value && (
                    <div
                      className={darkMode ? '' : 'text-xs text-gray-500 mt-1 truncate'}
                      style={darkMode ? {
                        fontSize: '12px',
                        color: 'rgba(255,255,255,0.5)',
                        marginTop: '4px',
                        overflow: 'hidden',
                        textOverflow: 'ellipsis',
                        whiteSpace: 'nowrap',
                      } : {}}
                    >
                      {action.value.length > 50 ? action.value.substring(0, 50) + '...' : action.value}
                    </div>
                  )}
                  {action.selector && (
                    <div
                      className={darkMode ? '' : 'text-xs text-blue-500 mt-1 font-mono truncate'}
                      style={darkMode ? {
                        fontSize: '11px',
                        color: '#60a5fa',
                        marginTop: '4px',
                        fontFamily: TYPOGRAPHY.mono,
                        overflow: 'hidden',
                        textOverflow: 'ellipsis',
                        whiteSpace: 'nowrap',
                      } : {}}
                    >
                      {action.selector}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      </div>

      {/* Playback Controls */}
      <div
        className={darkMode ? '' : 'border-t border-gray-200 p-4'}
        style={darkMode ? {
          borderTop: '1px solid rgba(255,255,255,0.1)',
          padding: '16px 24px',
        } : {}}
      >
        {/* Timeline */}
        <div
          ref={timelineRef}
          onClick={handleTimelineClick}
          className={darkMode ? '' : 'h-2 bg-gray-200 rounded-full mb-4 cursor-pointer relative'}
          style={darkMode ? {
            height: '8px',
            background: 'rgba(255,255,255,0.1)',
            borderRadius: '4px',
            marginBottom: '16px',
            cursor: 'pointer',
            position: 'relative',
          } : {}}
        >
          {/* Progress */}
          <div
            className={darkMode ? '' : 'absolute h-full bg-red-500 rounded-full'}
            style={{
              width: `${progress}%`,
              height: '100%',
              background: '#ef4444',
              borderRadius: '4px',
              position: 'absolute',
            }}
          />

          {/* Action markers */}
          {actions.map((action, idx) => {
            const markerPosition = recording?.duration_ms
              ? (action.timestamp_ms / recording.duration_ms) * 100
              : 0;
            const color = ACTION_COLORS[action.action_type] || '#94a3b8';

            return (
              <div
                key={idx}
                className={darkMode ? '' : 'absolute w-1 h-3 -top-0.5 transform -translate-x-1/2'}
                style={{
                  left: `${markerPosition}%`,
                  width: '3px',
                  height: '12px',
                  top: '-2px',
                  transform: 'translateX(-50%)',
                  background: idx === currentActionIndex ? color : 'rgba(255,255,255,0.3)',
                  borderRadius: '2px',
                  position: 'absolute',
                }}
              />
            );
          })}
        </div>

        {/* Controls */}
        <div
          className={darkMode ? '' : 'flex items-center justify-between'}
          style={darkMode ? { display: 'flex', alignItems: 'center', justifyContent: 'space-between' } : {}}
        >
          <div className="flex items-center gap-4">
            {/* Playback buttons */}
            <div className="flex items-center gap-2">
              <button
                onClick={handleStepBackward}
                disabled={currentActionIndex === 0}
                className={darkMode ? '' : 'p-2 rounded-lg bg-gray-100 hover:bg-gray-200 disabled:opacity-50'}
                style={darkMode ? {
                  padding: '8px 12px',
                  background: 'rgba(255,255,255,0.1)',
                  border: 'none',
                  borderRadius: '8px',
                  color: 'white',
                  cursor: currentActionIndex === 0 ? 'not-allowed' : 'pointer',
                  opacity: currentActionIndex === 0 ? 0.5 : 1,
                } : {}}
              >
                {'<<'}
              </button>

              <button
                onClick={handlePlayPause}
                className={darkMode
                  ? ''
                  : 'p-3 rounded-full bg-red-500 text-white hover:bg-red-600'
                }
                style={darkMode ? {
                  padding: '12px 24px',
                  background: '#ef4444',
                  border: 'none',
                  borderRadius: '999px',
                  color: 'white',
                  cursor: 'pointer',
                  fontWeight: '500',
                } : {}}
              >
                {isPlaying ? 'Pause' : 'Play'}
              </button>

              <button
                onClick={handleStepForward}
                disabled={currentActionIndex >= actions.length - 1}
                className={darkMode ? '' : 'p-2 rounded-lg bg-gray-100 hover:bg-gray-200 disabled:opacity-50'}
                style={darkMode ? {
                  padding: '8px 12px',
                  background: 'rgba(255,255,255,0.1)',
                  border: 'none',
                  borderRadius: '8px',
                  color: 'white',
                  cursor: currentActionIndex >= actions.length - 1 ? 'not-allowed' : 'pointer',
                  opacity: currentActionIndex >= actions.length - 1 ? 0.5 : 1,
                } : {}}
              >
                {'>>'}
              </button>
            </div>

            {/* Time display */}
            <span
              className={darkMode ? '' : 'text-sm text-gray-600 font-mono'}
              style={darkMode ? {
                fontSize: '14px',
                color: 'rgba(255,255,255,0.7)',
                fontFamily: TYPOGRAPHY.mono,
              } : {}}
            >
              {formatTime(currentAction?.timestamp_ms || 0)} / {formatTime(recording?.duration_ms || 0)}
            </span>
          </div>

          {/* Speed control */}
          <div className="flex items-center gap-2">
            <span
              className={darkMode ? '' : 'text-sm text-gray-500'}
              style={darkMode ? { fontSize: '14px', color: 'rgba(255,255,255,0.5)' } : {}}
            >
              Speed:
            </span>
            {[0.5, 1, 2, 4].map(speed => (
              <button
                key={speed}
                onClick={() => setPlaybackSpeed(speed)}
                className={darkMode
                  ? ''
                  : `px-2 py-1 rounded text-sm ${playbackSpeed === speed ? 'bg-red-500 text-white' : 'bg-gray-100 text-gray-600'}`
                }
                style={darkMode ? {
                  padding: '4px 10px',
                  background: playbackSpeed === speed ? '#ef4444' : 'rgba(255,255,255,0.1)',
                  color: 'white',
                  border: 'none',
                  borderRadius: '6px',
                  cursor: 'pointer',
                  fontSize: '13px',
                } : {}}
              >
                {speed}x
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
