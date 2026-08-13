import React, { createContext, useContext, useState, useMemo, useCallback } from 'react';

// One time window for the whole dashboard. Moving from Traces to Interactions
// to an agent's analytics should keep the period you were looking at — the
// question "what happened in the last hour?" shouldn't reset because you
// followed a link.
//
// `bucketSeconds` keeps chart bar counts near 30-60 as the window grows, and
// `days` exists because the agent analytics API takes days rather than minutes.
export const TIME_WINDOWS = [
  { id: '5m', label: '5m', minutes: 5, bucketSeconds: 10 },
  { id: '10m', label: '10m', minutes: 10, bucketSeconds: 20 },
  { id: '15m', label: '15m', minutes: 15, bucketSeconds: 30 },
  { id: '30m', label: '30m', minutes: 30, bucketSeconds: 60 },
  { id: '45m', label: '45m', minutes: 45, bucketSeconds: 60 },
  { id: '1h', label: '1h', minutes: 60, bucketSeconds: 120 },
  { id: '2h', label: '2h', minutes: 120, bucketSeconds: 240 },
  { id: '3h', label: '3h', minutes: 180, bucketSeconds: 300 },
  { id: '6h', label: '6h', minutes: 360, bucketSeconds: 600 },
  { id: '12h', label: '12h', minutes: 720, bucketSeconds: 1200 },
  { id: '1d', label: '1d', minutes: 1440, bucketSeconds: 1800 },
  { id: '3d', label: '3d', minutes: 4320, bucketSeconds: 7200 },
  { id: '7d', label: '7d', minutes: 10080, bucketSeconds: 14400 },
  { id: '30d', label: '30d', minutes: 43200, bucketSeconds: 86400 },
  { id: '90d', label: '90d', minutes: 129600, bucketSeconds: 259200 },
];

const DEFAULT_WINDOW_ID = '30m';
const STORAGE_KEY = 'activeagents.timeWindow';

const TimeWindowContext = createContext(null);

const findWindow = (id) => TIME_WINDOWS.find((w) => w.id === id);

export function TimeWindowProvider({ children }) {
  const [windowId, setWindowId] = useState(() => {
    try {
      const stored = localStorage.getItem(STORAGE_KEY);
      if (stored && findWindow(stored)) return stored;
    } catch {
      // private mode / storage disabled — fall through to the default
    }
    return DEFAULT_WINDOW_ID;
  });

  const setWindow = useCallback((id) => {
    if (!findWindow(id)) return;
    setWindowId(id);
    try {
      localStorage.setItem(STORAGE_KEY, id);
    } catch {
      // non-fatal: the window still applies for this session
    }
  }, []);

  const value = useMemo(() => {
    const index = TIME_WINDOWS.findIndex((w) => w.id === windowId);
    const timeWindow = TIME_WINDOWS[index] || findWindow(DEFAULT_WINDOW_ID);

    return {
      timeWindow,
      windowIndex: index,
      windows: TIME_WINDOWS,
      setWindow,
      zoomTo: (i) => {
        const next = TIME_WINDOWS[Math.min(Math.max(i, 0), TIME_WINDOWS.length - 1)];
        if (next) setWindow(next.id);
      },
      // Endpoints that take whole days round up, so a 45m window still asks
      // for one day rather than zero and silently returning nothing.
      days: Math.max(1, Math.ceil(timeWindow.minutes / 1440)),
    };
  }, [windowId, setWindow]);

  return <TimeWindowContext.Provider value={value}>{children}</TimeWindowContext.Provider>;
}

export function useTimeWindow() {
  const context = useContext(TimeWindowContext);
  if (!context) {
    throw new Error('useTimeWindow must be used within a TimeWindowProvider');
  }
  return context;
}
