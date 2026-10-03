// The messages between the dashboard and the session player frame
// (replay/player.js, served by SessionPlayerController).
//
// Both documents are on the dashboard's origin. Every message carries
// PLAYER_CHANNEL, and each side accepts a message only from the window it
// expects: the frame from its parent, the dashboard from the frame.
//
// Dashboard to frame:
//   load    { events }           replace the recording being replayed
//   append  { events }           add events to its end
//   seek    { offset, playing }  move `offset` ms into the recording, then play or hold
//   speed   { speed }            the playback speed multiplier
// Frame to dashboard:
//   ready                        the player is listening
//   loaded  { startTime, endTime }  the recording's range, epoch ms
//   finished                     playback reached the recording's end
//   error   { message }

export const PLAYER_CHANNEL = 'action-agent-session-player';

// The path, relative to the engine's mount, SessionPlayerController serves
// the frame at.
export const PLAYER_FRAME_PATH = '/session_player';

// The iframe sandbox the dashboard frames the player with. rrweb rebuilds
// the recorded page in an inner frame sandboxed to allow-same-origin alone,
// and that frame is unreachable from an opaque-origin parent.
export const PLAYER_FRAME_SANDBOX = 'allow-scripts allow-same-origin';

export function playerMessage(type, payload = {}) {
  return { ...payload, channel: PLAYER_CHANNEL, type };
}

// Whether `event` is a player message sent by `expectedSource` from
// `origin`.
export function isPlayerMessage(event, expectedSource, origin) {
  return Boolean(event)
    && expectedSource != null
    && event.source === expectedSource
    && event.origin === origin
    && event.data?.channel === PLAYER_CHANNEL
    && typeof event.data.type === 'string';
}

// The scale that fits a recorded viewport (`{ width, height }`) into the
// space available, never enlarging it. 1 when either size is unknown.
export function fitScale(recorded, available) {
  const width = Number(recorded?.width);
  const height = Number(recorded?.height);
  if (!(width > 0 && height > 0 && available?.width > 0 && available?.height > 0)) return 1;

  return Math.min(1, available.width / width, available.height / height);
}
