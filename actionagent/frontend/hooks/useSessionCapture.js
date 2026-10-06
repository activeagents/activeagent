import { useLayoutEffect, useState } from 'react';
import { createSessionCapture } from '../utils/sessionCapture.mjs';

// Records the calling view into a dashboard recording of conversation
// `contextId` for as long as the view is mounted and the conversation stays
// the same (utils/sessionCapture.mjs). Records nothing without a
// conversation, or without `recorderUrl`, which the dashboard page leaves
// out when the host turned capture off.
//
// Returns the capture's state.
export default function useSessionCapture(contextId, recorderUrl) {
  const [state, setState] = useState('idle');

  // A layout effect, because its cleanup has to stop the recorder before the
  // next view's DOM is committed: an effect's cleanup runs after the commit,
  // and the recorder would take in the first render of the view navigated to.
  useLayoutEffect(() => {
    if (!contextId || !recorderUrl) {
      setState('idle');
      return undefined;
    }

    let current = true;
    const capture = createSessionCapture({
      contextId,
      loadRecorder: () => import(recorderUrl),
      fetch: (path, init) => fetch(path, init),
      target: window,
      onStateChange: (next) => {
        if (current) setState(next);
      },
    });
    capture.start();

    return () => {
      current = false;
      capture.stop();
    };
  }, [contextId, recorderUrl]);

  return state;
}
