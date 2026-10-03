import assert from 'node:assert/strict';
import test from 'node:test';

import { PLAYER_CHANNEL, fitScale, isPlayerMessage, playerMessage } from '../utils/replayFrame.mjs';

const ORIGIN = 'https://dashboard.example';
const parent = { name: 'parent' };
const stranger = { name: 'another window' };

const event = (overrides = {}) => ({
  source: parent,
  origin: ORIGIN,
  data: playerMessage('seek', { offset: 1200, playing: true }),
  ...overrides,
});

test('a message carries the channel and its type over its payload', () => {
  assert.deepEqual(playerMessage('load', { events: [], type: 'spoofed', channel: 'other' }), {
    events: [],
    channel: PLAYER_CHANNEL,
    type: 'load',
  });
});

test('accepts a player message from the expected window and origin', () => {
  assert.equal(isPlayerMessage(event(), parent, ORIGIN), true);
});

test('refuses a message from any other window', () => {
  assert.equal(isPlayerMessage(event({ source: stranger }), parent, ORIGIN), false);
  assert.equal(isPlayerMessage(event({ source: null }), null, ORIGIN), false);
});

test('refuses a message from any other origin, including an opaque one', () => {
  assert.equal(isPlayerMessage(event({ origin: 'https://evil.example' }), parent, ORIGIN), false);
  assert.equal(isPlayerMessage(event({ origin: 'null' }), parent, ORIGIN), false);
});

test('refuses a message off the channel or without a type', () => {
  assert.equal(isPlayerMessage(event({ data: { type: 'seek' } }), parent, ORIGIN), false);
  assert.equal(isPlayerMessage(event({ data: { channel: PLAYER_CHANNEL } }), parent, ORIGIN), false);
  assert.equal(isPlayerMessage(event({ data: 'seek' }), parent, ORIGIN), false);
  assert.equal(isPlayerMessage(null, parent, ORIGIN), false);
});

test('fits a recorded viewport into the frame without enlarging it', () => {
  assert.equal(fitScale({ width: 1280, height: 720 }, { width: 640, height: 720 }), 0.5);
  assert.equal(fitScale({ width: 1280, height: 720 }, { width: 1280, height: 360 }), 0.5);
  assert.equal(fitScale({ width: 400, height: 300 }, { width: 1280, height: 720 }), 1);
});

test('keeps the recorded size when either size is unknown', () => {
  assert.equal(fitScale(null, { width: 640, height: 480 }), 1);
  assert.equal(fitScale({ width: 0, height: 720 }, { width: 640, height: 480 }), 1);
  assert.equal(fitScale({ width: 1280, height: 720 }, { width: 0, height: 0 }), 1);
});
