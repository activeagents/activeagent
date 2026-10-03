// The session player: rrweb's Replayer, run inside the frame
// SessionPlayerController serves. It is built as its own classic script
// (action_agent_replay.js), so the dashboard's bundle carries no rrweb code.
// It replays only what the dashboard that framed it posts (see
// utils/replayFrame.mjs for the messages).
import { Replayer } from '@rrweb/replay';
import replayerStyles from '@rrweb/replay/dist/style.css';
import { fitScale, isPlayerMessage, playerMessage } from '../utils/replayFrame.mjs';

const root = document.getElementById('session-player');
let replayer = null;
let viewport = null;

function post(type, payload) {
  window.parent.postMessage(playerMessage(type, payload), window.location.origin);
}

function fit() {
  const wrapper = root.querySelector('.replayer-wrapper');
  if (!wrapper || !viewport) return;

  const scale = fitScale(viewport, { width: window.innerWidth, height: window.innerHeight });
  wrapper.style.transformOrigin = 'top left';
  wrapper.style.transform = `scale(${scale})`;
  root.style.width = `${Math.floor(viewport.width * scale)}px`;
  root.style.height = `${Math.floor(viewport.height * scale)}px`;
}

function load(events) {
  if (replayer) replayer.destroy();
  root.replaceChildren();
  viewport = null;

  replayer = new Replayer(events, {
    root,
    showWarning: false,
    showDebug: false,
    mouseTail: false,
    skipInactive: false,
    triggerFocus: false,
    UNSAFE_replayCanvas: false,
  });
  replayer.on('resize', (dimension) => {
    viewport = dimension;
    fit();
  });
  replayer.on('finish', () => post('finished'));
  replayer.pause(0);

  const { startTime, endTime } = replayer.getMetaData();
  post('loaded', { startTime, endTime });
}

const handlers = {
  load: ({ events }) => load(events),
  append: ({ events }) => events.forEach((event) => replayer?.addEvent(event)),
  seek: ({ offset, playing }) => {
    if (!replayer) return;
    if (playing) replayer.play(offset);
    else replayer.pause(offset);
  },
  speed: ({ speed }) => replayer?.setConfig({ speed }),
};

const style = document.createElement('style');
style.textContent = replayerStyles;
document.head.appendChild(style);

window.addEventListener('resize', fit);
window.addEventListener('message', (event) => {
  if (!isPlayerMessage(event, window.parent, window.location.origin)) return;

  const handler = handlers[event.data.type];
  if (!handler) return;
  try {
    handler(event.data);
  } catch (error) {
    post('error', { message: error?.message || String(error) });
  }
});

post('ready');
