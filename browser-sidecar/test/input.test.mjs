import assert from 'node:assert/strict';
import test from 'node:test';

import { inputCommand, pagePoint } from '../lib/input.mjs';

const metadata = { deviceWidth: 1280, deviceHeight: 800, offsetTop: 0 };

test('scales a point given as fractions of the frame to the page', () => {
  assert.deepEqual(pagePoint({ x: 0.5, y: 0.25 }, metadata), { x: 640, y: 200 });
  assert.deepEqual(pagePoint({ x: 1, y: 1 }, { ...metadata, offsetTop: 10 }), { x: 1280, y: 810 });
  assert.equal(pagePoint({ x: 0.5, y: 0.5 }, null), null, 'nothing to scale by before the first frame');
  assert.equal(pagePoint({ x: 1.5, y: 0.5 }, metadata), null);
  assert.equal(pagePoint({ x: '0.5', y: 0.5 }, metadata), null);
  assert.equal(pagePoint({ x: 0.5, y: 0.5 }, { deviceWidth: 0, deviceHeight: 800 }), null);
});

test('relays mouse buttons and moves', () => {
  assert.deepEqual(inputCommand({ type: 'mouse', action: 'down', x: 0.25, y: 0.5, button: 'left', clickCount: 1, modifiers: 8 }, metadata), [
    'Input.dispatchMouseEvent', { type: 'mousePressed', x: 320, y: 400, button: 'left', modifiers: 8, clickCount: 1 },
  ]);
  assert.deepEqual(inputCommand({ type: 'mouse', action: 'up', x: 0.25, y: 0.5, button: 'right', clickCount: 2 }, metadata), [
    'Input.dispatchMouseEvent', { type: 'mouseReleased', x: 320, y: 400, button: 'right', modifiers: 0, clickCount: 2 },
  ]);
  assert.deepEqual(inputCommand({ type: 'mouse', action: 'move', x: 0, y: 0 }, metadata), [
    'Input.dispatchMouseEvent', { type: 'mouseMoved', x: 0, y: 0, button: 'none', modifiers: 0 },
  ]);
  assert.equal(inputCommand({ type: 'mouse', action: 'drag', x: 0, y: 0 }, metadata), null);
  assert.equal(inputCommand({ type: 'mouse', action: 'down', x: 0, y: 0, button: 'back', modifiers: 99 }, metadata)[1].button, 'left');
});

test('relays the wheel with its delta bounded', () => {
  assert.deepEqual(inputCommand({ type: 'wheel', x: 0.5, y: 0.5, deltaX: 0, deltaY: 120 }, metadata), [
    'Input.dispatchMouseEvent', { type: 'mouseWheel', x: 640, y: 400, deltaX: 0, deltaY: 120, modifiers: 0 },
  ]);
  assert.equal(inputCommand({ type: 'wheel', x: 0.5, y: 0.5, deltaY: 1e9 }, metadata)[1].deltaY, 10_000);
  assert.equal(inputCommand({ type: 'wheel', x: 0.5, y: 0.5, deltaY: 'far' }, metadata)[1].deltaY, 0);
});

test('a printable key types its character, and a shortcut types nothing', () => {
  assert.deepEqual(inputCommand({ type: 'key', action: 'down', key: 'a', code: 'KeyA' }, metadata), [
    'Input.dispatchKeyEvent', { type: 'keyDown', key: 'a', code: 'KeyA', modifiers: 0, windowsVirtualKeyCode: 65, text: 'a', unmodifiedText: 'a' },
  ]);
  assert.deepEqual(inputCommand({ type: 'key', action: 'down', key: 'a', code: 'KeyA', modifiers: 4 }, null), [
    'Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'a', code: 'KeyA', modifiers: 4, windowsVirtualKeyCode: 65 },
  ]);
  assert.deepEqual(inputCommand({ type: 'key', action: 'up', key: 'a', code: 'KeyA' }, metadata), [
    'Input.dispatchKeyEvent', { type: 'keyUp', key: 'a', code: 'KeyA', modifiers: 0, windowsVirtualKeyCode: 65 },
  ]);
});

test('named keys carry their key codes, and Enter types a carriage return', () => {
  assert.deepEqual(inputCommand({ type: 'key', action: 'down', key: 'Enter', code: 'Enter' }, metadata)[1], {
    type: 'keyDown', key: 'Enter', code: 'Enter', modifiers: 0, windowsVirtualKeyCode: 13, text: '\r', unmodifiedText: '\r',
  });
  assert.deepEqual(inputCommand({ type: 'key', action: 'down', key: 'Backspace', code: 'Backspace' }, metadata)[1], {
    type: 'rawKeyDown', key: 'Backspace', code: 'Backspace', modifiers: 0, windowsVirtualKeyCode: 8,
  });
  assert.equal(inputCommand({ type: 'key', action: 'down', key: 'ArrowDown', keyCode: 40 }, metadata)[1].windowsVirtualKeyCode, 40);
  assert.equal(inputCommand({ type: 'key', action: 'down', key: 'Dead' }, metadata)[1].windowsVirtualKeyCode, 0);
});

test('relays text as one insertion', () => {
  assert.deepEqual(inputCommand({ type: 'text', text: 'héllo wörld' }, metadata), ['Input.insertText', { text: 'héllo wörld' }]);
});

test('drops what a viewer may not send', () => {
  const refused = [
    null,
    {},
    { type: 'script', source: 'alert(1)' },
    { type: 'key', action: 'press', key: 'a' },
    { type: 'key', action: 'down', key: '' },
    { type: 'key', action: 'down', key: 'x'.repeat(40) },
    { type: 'text', text: '' },
    { type: 'text', text: 'x'.repeat(2001) },
    { type: 'text', text: 42 },
    { type: 'mouse', action: 'down', x: -0.1, y: 0.5 },
    { type: 'wheel', x: 0.5 },
  ];
  for (const message of refused) assert.equal(inputCommand(message, metadata), null, JSON.stringify(message));
});
