import { useCallback, useEffect, useRef, useState } from 'react';
import { axisStretchAt } from '../utils/replayTimeline.mjs';

// Plays a session along its playback axis (utils/replayTimeline.mjs).
//
// Returns the axis `position`, `playing`, `speed`, and `seekVersion`, which
// changes on every jump a browser replay has to follow: a seek, a step, and
// playback entering or leaving a shortened idle stretch. Playback stops at
// the end of the axis; playing again from there starts over.
export default function useReplayClock(axis) {
  const [position, setPosition] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [speed, setSpeed] = useState(1);
  const [seekVersion, setSeekVersion] = useState(0);
  const positionRef = useRef(0);
  const stretchRef = useRef(0);

  const moveTo = useCallback((axisMs, jumped) => {
    const next = Math.min(Math.max(axisMs, 0), axis.totalMs);
    const stretch = axisStretchAt(axis, next);
    positionRef.current = next;
    setPosition(next);
    if (jumped || stretch !== stretchRef.current) setSeekVersion((version) => version + 1);
    stretchRef.current = stretch;
    return next;
  }, [axis]);

  useEffect(() => {
    if (!playing) return undefined;

    let frame = null;
    let last = performance.now();
    const tick = (now) => {
      const next = moveTo(positionRef.current + (now - last) * speed, false);
      last = now;
      if (next >= axis.totalMs) {
        setPlaying(false);
        return;
      }
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [playing, speed, axis, moveTo]);

  const seek = useCallback((axisMs) => moveTo(axisMs, true), [moveTo]);

  const togglePlay = useCallback(() => {
    if (!playing && positionRef.current >= axis.totalMs) moveTo(0, true);
    setPlaying(!playing);
  }, [playing, axis, moveTo]);

  const pause = useCallback(() => setPlaying(false), []);

  return { position, playing, speed, seekVersion, seek, togglePlay, pause, setSpeed };
}
