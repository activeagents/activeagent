import React, { useCallback, useEffect, useReducer, useRef, useState } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { apiErrorMessage } from '../../utils/codeSessions.mjs';
import {
  agentBanner,
  closeMessage,
  controlLabel,
  encodeChunk,
  fileChooserWaitLabel,
  handoffReport,
  initialLiveViewState,
  keyMessage,
  leavesView,
  liveViewReducer,
  mouseMessage,
  pageLabel,
  personRequestBanner,
  releaseMessage,
  takeOverButton,
  textMessage,
  UPLOAD_CHUNK_BYTES,
  uploadPlan,
  uploadProgressLabel,
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

// An upload waits while this much is still queued on the socket, so frames
// keep arriving and the browser does not hold a whole file in its buffer.
const UPLOAD_BUFFERED_BYTES = 1024 * 1024;
const pause = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

// What the person driving is shown when the page asks for files: a file
// input of their own, as the page's would take (`chooser`, the sidecar's
// file_chooser), and Cancel; or how far the upload has got.
export function FileChooserPrompt({ chooser, upload, onFiles, onCancel }) {
  const { darkMode } = useTheme();
  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const strong = darkMode ? 'text-white' : 'text-gray-900';
  const several = chooser.multiple;

  return (
    <div
      role="dialog"
      aria-label="Choose a file for the page"
      data-testid="live-view-file-chooser"
      className={`absolute inset-x-4 top-4 p-3 rounded border shadow space-y-2 ${darkMode ? 'bg-gray-800 border-gray-600' : 'bg-white border-gray-300'}`}
    >
      <p className={`text-sm font-medium ${strong}`}>The page asked for {several ? 'files' : 'a file'}</p>
      <p className={`text-xs ${muted}`}>
        Choose {several ? `up to ${chooser.max_files} files` : 'one'} from this computer, or drop {several ? 'them' : 'it'} on the
        view. {chooser.accept ? `The page takes ${chooser.accept}. ` : ''}Only the browser receives the files, and they stay in the
        sandbox until the browser stops.
      </p>
      {upload ? (
        <p className={`text-xs ${strong}`} role="status">{uploadProgressLabel(upload)}</p>
      ) : (
        <input
          type="file"
          multiple={several}
          accept={chooser.accept || undefined}
          onChange={(event) => onFiles(event.target.files)}
          aria-label={several ? 'Files for the page' : 'File for the page'}
          className={`block text-xs ${strong}`}
        />
      )}
      <button
        type="button"
        onClick={onCancel}
        className={`px-3 py-1 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`}
      >
        Cancel
      </button>
    </div>
  );
}

// A sandbox browser's live view: the page on screen, drawn from the frames
// the browser streams, with "Watch live", "Take over" and "Hand back".
// While this viewer holds control, its mouse and wheel over the frame go to
// the page, and so do its keys while the frame has keyboard focus. It holds
// control, and the agent waits, until Hand back or Stop watching. When the
// page asks for a file while this viewer drives, it is chosen here (or
// dropped on the view) and sent to the browser. `headed`
// is whether the browser also has a window open on the dashboard's machine,
// and `watchOnOpen` starts watching when the view is first shown.
// `onHandBack` is told, with handoffReport's shape, each time this viewer
// hands control back after driving, so a conversation with the agent can
// say what happened. `handBackLabel` renames the Hand back button.
export default function LiveView({ sessionId, headed = false, watchOnOpen = false, onHandBack = null, handBackLabel = 'Hand back' }) {
  const { darkMode } = useTheme();
  const [state, dispatch] = useReducer(liveViewReducer, initialLiveViewState);
  const [connection, setConnection] = useState('idle'); // idle | connecting | open
  const [notice, setNotice] = useState(null);
  const [taking, setTaking] = useState(false);
  const [upload, setUpload] = useState(null); // { sent, total }
  const socketRef = useRef(null);
  const closingRef = useRef(false);
  // Counts calls to watch and disconnect, so a watch whose ticket arrives
  // after Stop watching, or after the view is gone, opens nothing.
  const attemptRef = useRef(0);
  const mineRef = useRef(false);
  const canvasRef = useRef(null);
  const controlButtonRef = useRef(null);
  const frameQueue = useRef({ pending: null, decoding: false });
  const moveFrame = useRef({ message: null, scheduled: false });
  const lastPoint = useRef(null);
  const lastEscape = useRef(null);
  // Counts uploads begun and cancelled, so a cancelled one sends no more.
  const uploadRef = useRef(0);
  const mine = state.control.mine;
  // When this viewer last took control, for the handoff report.
  const takenAtRef = useRef(null);
  const latest = useRef(state);
  latest.current = state;
  useEffect(() => {
    if (mine) {
      takenAtRef.current = state.control.since || Date.now();
      return;
    }
    if (takenAtRef.current === null) return;
    const takenAt = takenAtRef.current;
    takenAtRef.current = null;
    onHandBack?.(handoffReport({ by: null, takenAt, releasedAt: Date.now(), page: latest.current.page }));
  }, [mine]);

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

  // A holder hands back before closing, so the agent goes on at once rather
  // than after the grace period the sidecar gives a dropped connection.
  const disconnect = useCallback(() => {
    attemptRef.current += 1;
    const ws = socketRef.current;
    if (!ws) {
      setConnection('idle');
      return;
    }
    if (mineRef.current && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'hand_back' }));
    closingRef.current = true;
    ws.close(1000);
  }, []);

  useEffect(() => disconnect, [disconnect]);

  const watch = async () => {
    attemptRef.current += 1;
    const attempt = attemptRef.current;
    setNotice(null);
    setConnection('connecting');
    try {
      const { ticket, url } = await requestTicket(sessionId, 'view');
      if (attemptRef.current !== attempt) return;

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
        if ((message.type === 'file_upload' && message.status !== 'progress') || (message.type === 'file_chooser' && !message.chooser)) {
          uploadRef.current += 1;
          setUpload(null);
        }
        dispatch(message);
      };
      ws.onclose = (event) => {
        if (socketRef.current !== ws) return;
        socketRef.current = null;
        uploadRef.current += 1;
        setUpload(null);
        setConnection('idle');
        dispatch({ type: 'reset' });
        setNotice(closeMessage(event.code, { requested: closingRef.current }));
      };
    } catch (e) {
      if (attemptRef.current !== attempt) return;
      setConnection('idle');
      setNotice(e.message);
    }
  };

  const watchedOnOpen = useRef(false);
  useEffect(() => {
    if (!watchOnOpen || watchedOnOpen.current) return;
    watchedOnOpen.current = true;
    void watch();
  }, [watchOnOpen]);

  const takeOver = async () => {
    dispatch({ type: 'clear_error' });
    setTaking(true);
    try {
      const { ticket } = await requestTicket(sessionId, 'control');
      send({ type: 'take_control', ticket });
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

  // Sends the files a person chose, or dropped on the view, to the page's
  // file chooser: their names and sizes, then their bytes a chunk at a time.
  const uploadFiles = async (fileList) => {
    const chooser = state.fileChooser;
    const plan = uploadPlan(fileList, chooser);
    if (plan.error) {
      setNotice(plan.error);
      return;
    }
    const ws = socketRef.current;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;

    uploadRef.current += 1;
    const attempt = uploadRef.current;
    setNotice(null);
    dispatch({ type: 'clear_error' });
    send({ type: 'file_upload', chooser: chooser.id, files: plan.files });
    let sent = 0;
    setUpload({ sent, total: plan.total });
    try {
      for (const file of Array.from(fileList)) {
        for (let offset = 0; offset < file.size; offset += UPLOAD_CHUNK_BYTES) {
          while (ws.bufferedAmount > UPLOAD_BUFFERED_BYTES && uploadRef.current === attempt) await pause(50);
          if (uploadRef.current !== attempt || ws.readyState !== WebSocket.OPEN) return;
          const bytes = new Uint8Array(await file.slice(offset, offset + UPLOAD_CHUNK_BYTES).arrayBuffer());
          send({ type: 'file_chunk', chooser: chooser.id, data: encodeChunk(bytes) });
          sent += bytes.length;
          setUpload({ sent, total: plan.total });
        }
      }
    } catch (e) {
      setNotice(`Could not read the file: ${e.message}`);
      cancelChooser();
    }
  };

  const cancelChooser = () => {
    uploadRef.current += 1;
    setUpload(null);
    if (state.fileChooser) send({ type: 'file_cancel', chooser: state.fileChooser.id });
  };

  const chooserOpen = mine && Boolean(state.fileChooser);
  const drop = chooserOpen ? {
    onDragOver: (event) => {
      event.preventDefault();
      event.dataTransfer.dropEffect = 'copy';
    },
    onDrop: (event) => {
      event.preventDefault();
      if (!upload) void uploadFiles(event.dataTransfer.files);
    },
  } : {};

  // Focus goes to the frame when this view takes control, and leaves it when
  // control is handed back or taken away.
  useEffect(() => {
    mineRef.current = mine;
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
    // Every other key, Tab included, goes to the page, so a quick second
    // Escape is the way out by keyboard. It moves focus to Hand back.
    onKeyDown: (event) => {
      if (leavesView(event, lastEscape.current)) {
        event.preventDefault();
        lastEscape.current = null;
        controlButtonRef.current?.focus();
        return;
      }
      lastEscape.current = event.key === 'Escape' && !event.repeat ? event.timeStamp : null;
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
  const personBanner = personRequestBanner(state);
  const holder = controlLabel(state);
  const takeOverAction = takeOverButton(state, { taking });
  const page = pageLabel(state.page);
  const waitingForFile = fileChooserWaitLabel(state);
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
        {/* One button that changes, so focus stays on it when control changes hands. */}
        {open && (mine ? (
          <button ref={controlButtonRef} type="button" onClick={handBack} className={primaryButton}>{handBackLabel}</button>
        ) : (
          <button ref={controlButtonRef} type="button" onClick={takeOver} disabled={takeOverAction.disabled} className={primaryButton}>
            {takeOverAction.label}
          </button>
        ))}
        {holder && <span className={`text-xs font-medium ${strong}`}>{holder}</span>}
        {connection === 'connecting' && <span className={`text-xs ${muted}`}>Connecting…</span>}
      </div>

      {notice && <p className={`text-xs ${muted}`} role="status">{notice}</p>}
      {state.error && <p className={`text-xs ${darkMode ? 'text-red-400' : 'text-red-600'}`} role="alert">{state.error}</p>}
      {personBanner && (
        <p
          role="alert"
          data-testid="live-view-person-request"
          className={`p-2 rounded text-xs border ${darkMode ? 'bg-blue-900/20 border-blue-800 text-blue-200' : 'bg-blue-50 border-blue-200 text-blue-800'}`}
        >
          {personBanner}{open ? ' Take over to help, then hand back.' : ' Watch live, then take over to help.'}
        </p>
      )}
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
          {waitingForFile && <p className={`text-xs ${muted}`} role="status">{waitingForFile}</p>}
          <div className="relative" data-testid="live-view-frame" {...drop}>
            <canvas
              ref={canvasRef}
              tabIndex={mine ? 0 : -1}
              role={mine ? 'application' : 'img'}
              aria-label={mine ? "The sandbox's browser: your mouse and keys go to it. Press Escape twice to leave it." : "Live view of the sandbox's browser"}
              className={`block w-full rounded border bg-black ${mine ? 'cursor-default outline-none focus:ring-2 focus:ring-blue-500' : ''} ${darkMode ? 'border-gray-700' : 'border-gray-200'}`}
              style={{ aspectRatio: frameSize ? `${frameSize.width} / ${frameSize.height}` : '16 / 10' }}
              {...pointer}
            />
            {chooserOpen && (
              <FileChooserPrompt
                chooser={state.fileChooser}
                upload={upload}
                onFiles={(files) => void uploadFiles(files)}
                onCancel={cancelChooser}
              />
            )}
          </div>
          {mine && (
            <p className={`text-xs ${muted}`}>
              Your mouse and keys go to the browser, and the agent waits until you hand back. Press Escape twice to move focus
              out of the view. That, or clicking outside it, only stops your keys reaching the browser: the agent keeps waiting
              until you press Hand back or Stop watching.
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
