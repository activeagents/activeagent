import React, { useCallback, useEffect, useReducer, useRef, useState } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { apiErrorMessage } from '../../utils/codeSessions.mjs';
import {
  agentBanner,
  closeMessage,
  controlLabel,
  initialLiveViewState,
  keyMessage,
  liveViewReducer,
  mouseMessage,
  pageLabel,
  releaseMessage,
  textMessage,
  wheelMessage,
} from '../../utils/liveView.mjs';

// Asks the dashboard for a ticket into the live view: { ticket, url }.
async function requestTicket(sessionId, mode) {
  const res = await fetch(`/api/sandboxes/${encodeURIComponent(sessionId)}/browser/tickets`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mode }),
  });
  const data = await res.json().catch(() => ({}));
  if (res.status === 403 && data.code === 'forbidden') throw new Error('You do not have permission to take over this browser.');
  if (!res.ok) throw new Error(apiErrorMessage(data, `Could not open the live view (HTTP ${res.status}).`));
  return data;
}

// Whether a key press is the paste shortcut, which is left to the browser so
// its paste event carries the clipboard's text.
const isPasteShortcut = (event) => (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'v';

// A sandbox browser's live view: the page on screen, drawn from the frames
// the browser streams, with "Watch live", "Take over" and "Hand back".
// While this viewer holds control, the frame takes keyboard focus and its
// mouse, wheel and keys go to the page; clicking outside it, or Hand back,
// stops that. `headed` is whether the browser also has a window open on the
// dashboard's machine.
export default function LiveView({ sessionId, headed = false }) {
  const { darkMode } = useTheme();
  const [state, dispatch] = useReducer(liveViewReducer, initialLiveViewState);
  const [connection, setConnection] = useState('idle'); // idle | connecting | open
  const [notice, setNotice] = useState(null);
  const [taking, setTaking] = useState(false);
  const socketRef = useRef(null);
  const closingRef = useRef(false);
  const canvasRef = useRef(null);
  const frameQueue = useRef({ pending: null, decoding: false });
  const moveFrame = useRef({ message: null, scheduled: false });
  const lastPoint = useRef(null);
  const mine = state.control.mine;

  const send = useCallback((message) => {
    const ws = socketRef.current;
    if (message && ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(message));
  }, []);

  // Draws the newest frame. Frames that arrive while one decodes are skipped
  // for the latest.
  const draw = useCallback((frame) => {
    const queue = frameQueue.current;
    queue.pending = frame;
    if (queue.decoding) return;

    const next = () => {
      const current = queue.pending;
      queue.pending = null;
      queue.decoding = Boolean(current);
      if (!current) return;

      const image = new Image();
      image.onload = () => {
        const canvas = canvasRef.current;
        if (canvas) {
          if (canvas.width !== image.naturalWidth || canvas.height !== image.naturalHeight) {
            canvas.width = image.naturalWidth;
            canvas.height = image.naturalHeight;
          }
          canvas.getContext('2d')?.drawImage(image, 0, 0);
        }
        next();
      };
      image.onerror = next;
      image.src = `data:image/jpeg;base64,${current.data}`;
    };
    next();
  }, []);

  const disconnect = useCallback(() => {
    const ws = socketRef.current;
    if (!ws) return;
    closingRef.current = true;
    ws.close(1000);
  }, []);

  useEffect(() => disconnect, [disconnect]);

  const watch = async () => {
    setNotice(null);
    setConnection('connecting');
    try {
      const { ticket, url } = await requestTicket(sessionId, 'view');
      const ws = new WebSocket(url);
      socketRef.current = ws;
      closingRef.current = false;
      ws.onopen = () => ws.send(JSON.stringify({ type: 'auth', ticket }));
      ws.onmessage = (event) => {
        let message;
        try {
          message = JSON.parse(event.data);
        } catch (_error) {
          return;
        }
        if (message.type === 'ready') setConnection('open');
        if (message.type === 'frame') draw(message);
        dispatch(message);
      };
      ws.onclose = (event) => {
        if (socketRef.current !== ws) return;
        socketRef.current = null;
        setConnection('idle');
        dispatch({ type: 'reset' });
        setNotice(closeMessage(event.code, { requested: closingRef.current }));
      };
    } catch (e) {
      setConnection('idle');
      setNotice(e.message);
    }
  };

  // A watching view sends a control ticket with its first Take over; once it
  // has held control it may take it again without one.
  const takeOver = async () => {
    dispatch({ type: 'clear_error' });
    setTaking(true);
    try {
      if (state.canControl) {
        send({ type: 'take_control' });
      } else {
        const { ticket } = await requestTicket(sessionId, 'control');
        send({ type: 'take_control', ticket });
      }
    } catch (e) {
      setNotice(e.message);
    } finally {
      setTaking(false);
    }
  };

  const handBack = () => {
    send({ type: 'hand_back' });
    canvasRef.current?.blur();
  };

  // Focus goes to the frame when this view takes control, and leaves it when
  // control is handed back or taken away.
  useEffect(() => {
    if (mine) canvasRef.current?.focus();
    else canvasRef.current?.blur();
  }, [mine]);

  // The wheel needs a listener that may cancel scrolling the dashboard,
  // which React's onWheel cannot be.
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || !mine) return undefined;
    const onWheel = (event) => {
      event.preventDefault();
      send(wheelMessage(event, canvas.getBoundingClientRect()));
    };
    canvas.addEventListener('wheel', onWheel, { passive: false });
    return () => canvas.removeEventListener('wheel', onWheel);
  }, [mine, send, connection]);

  const rect = () => canvasRef.current?.getBoundingClientRect();
  const sendPointer = (message) => {
    if (!message) return;
    lastPoint.current = { x: message.x, y: message.y };
    send(message);
  };
  const pointer = mine ? {
    // The button is released wherever the pointer is by then: outside the
    // frame, at the last place it was over it.
    onMouseDown: (event) => {
      event.preventDefault();
      canvasRef.current?.focus();
      sendPointer(mouseMessage('down', event, rect()));
      window.addEventListener('mouseup', (up) => sendPointer(releaseMessage(up, rect(), lastPoint.current)), { once: true });
    },
    // One move per animation frame is enough to follow the pointer.
    onMouseMove: (event) => {
      const move = moveFrame.current;
      move.message = mouseMessage('move', event, rect());
      if (move.scheduled) return;
      move.scheduled = true;
      requestAnimationFrame(() => {
        move.scheduled = false;
        sendPointer(move.message);
        move.message = null;
      });
    },
    onContextMenu: (event) => event.preventDefault(),
    onKeyDown: (event) => {
      if (isPasteShortcut(event)) return;
      const message = keyMessage('down', event);
      if (!message) return;
      event.preventDefault();
      send(message);
    },
    onKeyUp: (event) => {
      if (isPasteShortcut(event)) return;
      const message = keyMessage('up', event);
      if (!message) return;
      event.preventDefault();
      send(message);
    },
    onPaste: (event) => {
      event.preventDefault();
      send(textMessage(event.clipboardData?.getData('text/plain')));
    },
  } : {};

  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const strong = darkMode ? 'text-white' : 'text-gray-900';
  const secondaryButton = `px-3 py-1 text-sm rounded disabled:opacity-50 ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`;
  const primaryButton = 'px-3 py-1 text-sm rounded text-white bg-blue-600 hover:bg-blue-700 disabled:opacity-50';
  const banner = agentBanner(state);
  const holder = controlLabel(state);
  const page = pageLabel(state.page);
  const open = connection === 'open';
  const { frameSize } = state;

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        {connection === 'idle' ? (
          <button type="button" onClick={watch} className={secondaryButton}>Watch live</button>
        ) : (
          <button type="button" onClick={disconnect} className={secondaryButton}>Stop watching</button>
        )}
        {open && !mine && (
          <button type="button" onClick={takeOver} disabled={taking || state.control.held} className={primaryButton}>
            {taking ? 'Taking over…' : 'Take over'}
          </button>
        )}
        {open && mine && <button type="button" onClick={handBack} className={primaryButton}>Hand back</button>}
        {holder && <span className={`text-xs font-medium ${strong}`}>{holder}</span>}
        {connection === 'connecting' && <span className={`text-xs ${muted}`}>Connecting…</span>}
      </div>

      {notice && <p className={`text-xs ${muted}`} role="status">{notice}</p>}
      {state.error && <p className={`text-xs ${darkMode ? 'text-red-400' : 'text-red-600'}`} role="alert">{state.error}</p>}
      {banner && (
        <p
          role="status"
          className={`p-2 rounded text-xs border ${darkMode ? 'bg-amber-900/20 border-amber-800 text-amber-300' : 'bg-amber-50 border-amber-200 text-amber-800'}`}
        >
          {banner}
        </p>
      )}

      {connection !== 'idle' && (
        <div className="space-y-1">
          {page && <p className={`text-xs font-mono truncate ${muted}`} title={page}>{page}</p>}
          <canvas
            ref={canvasRef}
            tabIndex={mine ? 0 : -1}
            role={mine ? 'application' : 'img'}
            aria-label={mine ? "The sandbox's browser: your mouse and keys go to it" : "Live view of the sandbox's browser"}
            className={`block w-full rounded border bg-black ${mine ? 'cursor-default outline-none focus:ring-2 focus:ring-blue-500' : ''} ${darkMode ? 'border-gray-700' : 'border-gray-200'}`}
            style={{ aspectRatio: frameSize ? `${frameSize.width} / ${frameSize.height}` : '16 / 10' }}
            {...pointer}
          />
          {mine && (
            <p className={`text-xs ${muted}`}>
              While the view has focus, your mouse and keys go to the browser and the agent waits for you. Click outside it, or
              Hand back, to stop.
            </p>
          )}
        </div>
      )}

      {headed && (
        <p className={`text-xs ${muted}`}>
          This browser also has a window open on this machine. Clicking or typing in that window changes the page too, but the
          agent does not wait for it: take over here first.
        </p>
      )}
    </div>
  );
}
