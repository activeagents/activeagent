import { useCallback, useEffect, useRef, useState } from 'react';
import {
  INPUT_REQUESTS_CHANGED,
  INPUT_REQUESTS_REFRESH_MS,
  inputRequestsPath,
} from '../utils/inputRequests.mjs';

// Tells every list and count of input requests on the page to refetch: after
// this tab answers or declines one, or sees a run pause.
export function notifyInputRequestsChanged() {
  window.dispatchEvent(new CustomEvent(INPUT_REQUESTS_CHANGED));
}

/**
 * The caller's pending input requests, refetched every `intervalMs`, whenever
 * `refreshKey` changes, and on notifyInputRequestsChanged. The engine pushes
 * no input request updates, so polling is how another tab's or another
 * person's answer shows up here.
 *
 * @param {object} options
 * @param {(number|string|null)} [options.agentId] only this agent's requests
 * @param {*} [options.refreshKey] refetches when it changes (the current view)
 * @param {boolean} [options.enabled]
 * @param {number} [options.intervalMs]
 * @returns {{ requests: (Array|null), error: (string|null), refresh: Function }}
 *   `requests` is null until the first response arrives
 */
export function useInputRequests({ agentId = null, refreshKey, enabled = true, intervalMs = INPUT_REQUESTS_REFRESH_MS } = {}) {
  const [requests, setRequests] = useState(null);
  const [error, setError] = useState(null);
  // A response to an earlier request than the latest one is stale.
  const latestRef = useRef(0);

  const refresh = useCallback(async () => {
    const ticket = ++latestRef.current;
    try {
      const response = await fetch(inputRequestsPath({ agentId }));
      if (!response.ok) throw new Error(`Request failed (${response.status})`);
      const body = await response.json();
      if (ticket !== latestRef.current) return;
      setRequests(Array.isArray(body.input_requests) ? body.input_requests : []);
      setError(null);
    } catch (failure) {
      if (ticket !== latestRef.current) return;
      setError(failure.message);
    }
  }, [agentId]);

  useEffect(() => {
    if (!enabled) return undefined;
    refresh();
    const timer = setInterval(refresh, intervalMs);
    window.addEventListener(INPUT_REQUESTS_CHANGED, refresh);
    return () => {
      clearInterval(timer);
      window.removeEventListener(INPUT_REQUESTS_CHANGED, refresh);
      latestRef.current += 1;
    };
  }, [enabled, refresh, intervalMs, refreshKey]);

  return { requests, error, refresh };
}

export default useInputRequests;
