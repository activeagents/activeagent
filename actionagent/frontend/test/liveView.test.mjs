import assert from 'node:assert/strict';
import test from 'node:test';
import {
  agentBanner,
  browserStartBody,
  browserStatus,
  closeMessage,
  controlLabel,
  encodeChunk,
  fileChooserWaitLabel,
  framePoint,
  initialLiveViewState,
  isBrowserActive,
  keyMessage,
  LEAVE_VIEW_MS,
  leavesView,
  liveViewReducer,
  modifierMask,
  mouseMessage,
  pageLabel,
  releaseMessage,
  takeOverButton,
  textMessage,
  UPLOAD_CHUNK_BYTES,
  uploadPlan,
  uploadProgressLabel,
  wheelMessage,
} from '../utils/liveView.mjs';

const rect = { left: 100, top: 50, width: 640, height: 400 };
const at = (clientX, clientY, extra = {}) => ({ clientX, clientY, altKey: false, ctrlKey: false, metaKey: false, shiftKey: false, ...extra });

test('a point on the drawn frame is a fraction of it, wherever and however large the frame is drawn', () => {
  assert.deepEqual(framePoint(420, 250, rect), { x: 0.5, y: 0.5 });
  assert.deepEqual(framePoint(100, 50, rect), { x: 0, y: 0 });
  assert.deepEqual(framePoint(740, 450, rect), { x: 1, y: 1 });
  assert.equal(framePoint(99, 250, rect), null, 'outside the frame');
  assert.equal(framePoint(420, 250, { ...rect, width: 0 }), null, 'a frame not drawn yet');
  assert.equal(framePoint(420, 250, null), null);
});

test('modifier keys become the CDP bit field', () => {
  assert.equal(modifierMask(at(0, 0)), 0);
  assert.equal(modifierMask(at(0, 0, { altKey: true, shiftKey: true })), 9);
  assert.equal(modifierMask(at(0, 0, { ctrlKey: true, metaKey: true })), 6);
});

test('mouse buttons and moves are sent at their place on the frame', () => {
  assert.deepEqual(mouseMessage('down', at(260, 150, { button: 0, detail: 2 }), rect), {
    type: 'mouse', action: 'down', x: 0.25, y: 0.25, modifiers: 0, button: 'left', clickCount: 2,
  });
  assert.deepEqual(mouseMessage('up', at(260, 150, { button: 2, detail: 0, shiftKey: true }), rect), {
    type: 'mouse', action: 'up', x: 0.25, y: 0.25, modifiers: 8, button: 'right', clickCount: 1,
  });
  assert.equal(mouseMessage('move', at(260, 150, { buttons: 1 }), rect).button, 'left', 'a move with the button held drags');
  assert.equal(mouseMessage('move', at(260, 150, { buttons: 0 }), rect).button, 'none');
  assert.equal(mouseMessage('down', at(0, 0, { button: 0 }), rect), null);
});

test('a button pressed on the frame is released where the pointer is, or where it left the frame', () => {
  assert.equal(releaseMessage(at(420, 250, { button: 0 }), rect, { x: 0.1, y: 0.1 }).x, 0.5);
  assert.deepEqual(releaseMessage(at(2000, 2000, { button: 2, shiftKey: true }), rect, { x: 0.9, y: 0.4 }), {
    type: 'mouse', action: 'up', x: 0.9, y: 0.4, modifiers: 8, button: 'right', clickCount: 1,
  });
  assert.equal(releaseMessage(at(2000, 2000, { button: 0 }), rect, null), null);
});

test('the wheel is sent in pixels whatever unit it scrolled in', () => {
  assert.deepEqual(wheelMessage(at(420, 250, { deltaX: 0, deltaY: 120, deltaMode: 0 }), rect), {
    type: 'wheel', x: 0.5, y: 0.5, deltaX: 0, deltaY: 120, modifiers: 0,
  });
  assert.equal(wheelMessage(at(420, 250, { deltaX: 0, deltaY: 3, deltaMode: 1 }), rect).deltaY, 48);
  assert.equal(wheelMessage(at(420, 250, { deltaX: 1, deltaY: 0, deltaMode: 2 }), rect).deltaX, 800);
  assert.equal(wheelMessage(at(0, 0, { deltaY: 1 }), rect), null);
});

test('keys are sent as they were pressed, except while an input method composes', () => {
  assert.deepEqual(keyMessage('down', { key: 'a', code: 'KeyA', keyCode: 65, ctrlKey: true }), {
    type: 'key', action: 'down', key: 'a', code: 'KeyA', keyCode: 65, modifiers: 2,
  });
  assert.equal(keyMessage('up', { key: 'Enter', code: 'Enter', keyCode: 13 }).action, 'up');
  assert.equal(keyMessage('down', { key: 'a', isComposing: true }), null);
  assert.equal(keyMessage('down', { key: 'Process' }), null);
  assert.equal(keyMessage('down', { key: '' }), null);
});

test('pasted or composed text is sent as one insertion, up to the limit', () => {
  assert.deepEqual(textMessage('こんにちは'), { type: 'text', text: 'こんにちは' });
  assert.equal(textMessage('x'.repeat(3000)).text.length, 2000);
  assert.equal(textMessage(''), null);
  assert.equal(textMessage(undefined), null);
});

test('the state follows what the sidecar says', () => {
  let state = liveViewReducer(initialLiveViewState, {
    type: 'ready',
    control: { held: true, mine: false, by: 'Grace', since: 1 },
    agent: { waiting: false, tool: null, since: null },
    page: { url: 'http://127.0.0.1:4100/orders', tab: 1, tabs: 1 },
  });
  assert.equal(state.ready, true);
  assert.equal(state.control.yours, false, 'a sidecar that does not say is taken to mean someone else');
  assert.equal(controlLabel(state), 'Held by Grace');

  state = liveViewReducer(state, { type: 'frame', data: 'x', width: 1280, height: 800 });
  assert.deepEqual(state.frameSize, { width: 1280, height: 800 });
  assert.equal(liveViewReducer(state, { type: 'frame', data: 'y', width: 1280, height: 800 }), state, 'a frame of the same size changes nothing');

  state = liveViewReducer(state, { type: 'control', held: true, mine: false, yours: true, by: 'Ada', since: 2 });
  assert.equal(controlLabel(state), 'You are driving in another view');

  state = liveViewReducer(state, { type: 'control', held: true, mine: true, yours: true, by: 'Ada', since: 2 });
  assert.equal(controlLabel(state), 'You are driving');

  state = liveViewReducer(state, { type: 'page', page: { url: 'http://127.0.0.1:4100/cart', tab: 2, tabs: 3 } });
  assert.equal(pageLabel(state.page), 'http://127.0.0.1:4100/cart · tab 2 of 3');

  state = liveViewReducer(state, { type: 'error', code: 'held', message: 'Grace is driving the browser' });
  assert.equal(state.error, 'Grace is driving the browser');
  assert.equal(liveViewReducer(state, { type: 'clear_error' }).error, null);
  assert.equal(liveViewReducer(state, { type: 'reset' }), initialLiveViewState);
  assert.equal(liveViewReducer(state, { type: 'something_new' }), state);
});

test('a banner shows while an agent waits for the person driving', () => {
  const waiting = { waiting: true, tool: 'browser_click', since: 1 };
  const mine = { ...initialLiveViewState, control: { held: true, mine: true, by: 'Ada', since: 1 }, agent: waiting };
  assert.equal(agentBanner(mine), 'The agent is waiting for you to hand back control (browser_click).');

  const elsewhere = { ...mine, control: { held: true, mine: false, yours: true, by: 'Ada', since: 1 } };
  assert.equal(agentBanner(elsewhere), 'The agent is waiting for you to hand back control in your other view (browser_click).');

  const theirs = { ...mine, control: { held: true, mine: false, yours: false, by: 'Grace', since: 1 } };
  assert.equal(agentBanner(theirs), 'The agent is waiting for Grace to hand back control (browser_click).');

  assert.equal(agentBanner({ ...mine, agent: initialLiveViewState.agent }), null);
  assert.equal(agentBanner({ ...initialLiveViewState, agent: waiting }), null, 'nobody holds control any more');
});

test('Take over is offered when nobody drives, and as Continue driving here when the driver is you in another view', () => {
  const control = (fields) => ({ ...initialLiveViewState, control: { ...initialLiveViewState.control, ...fields } });

  assert.deepEqual(takeOverButton(control({})), { label: 'Take over', disabled: false });
  assert.deepEqual(takeOverButton(control({ held: true, by: 'Grace' })), { label: 'Take over', disabled: true });
  assert.deepEqual(takeOverButton(control({ held: true, yours: true, by: 'Ada' })), { label: 'Continue driving here', disabled: false });
  assert.deepEqual(takeOverButton(control({}), { taking: true }), { label: 'Taking over…', disabled: true });
});

test('a second quick press of Escape leaves the view, and nothing else does', () => {
  const escape = (timeStamp, extra = {}) => ({ key: 'Escape', repeat: false, timeStamp, ...extra });

  assert.equal(leavesView(escape(1000), 700), true);
  assert.equal(leavesView(escape(700 + LEAVE_VIEW_MS), 700), true);
  assert.equal(leavesView(escape(701 + LEAVE_VIEW_MS), 700), false, 'too slow: it goes to the page');
  assert.equal(leavesView(escape(1000), null), false, 'the first press goes to the page');
  assert.equal(leavesView(escape(1000, { repeat: true }), 700), false, 'holding Escape down');
  assert.equal(leavesView({ key: 'Tab', repeat: false, timeStamp: 1000 }, 700), false);
});

test('a page is labelled with its tab only when there are several', () => {
  assert.equal(pageLabel({ url: 'http://127.0.0.1:4100/', tab: 1, tabs: 1 }), 'http://127.0.0.1:4100/');
  assert.equal(pageLabel({ url: null, tab: 1, tabs: 1 }), 'a page with no address to show');
  assert.equal(pageLabel(null), null);
});

test('a closed connection says why, unless the viewer closed it', () => {
  assert.equal(closeMessage(1001), 'The browser stopped.');
  assert.match(closeMessage(4401), /did not accept the ticket/);
  assert.match(closeMessage(1006), /lost its connection/);
  assert.equal(closeMessage(1000, { requested: true }), null);
});

test("a sandbox browser's status, and how one is started", () => {
  assert.deepEqual(browserStatus({ status: 'running' }), { label: 'Running', tone: 'success' });
  assert.equal(browserStatus({ status: null }), null);
  assert.equal(browserStatus(undefined), null);
  assert.equal(isBrowserActive({ status: 'starting' }), true);
  assert.equal(isBrowserActive({ status: 'failed' }), false);

  assert.deepEqual(browserStartBody({ inWindow: true, modes: ['headless', 'headed'] }), { mode: 'headed' });
  assert.deepEqual(browserStartBody({ inWindow: true, modes: ['headless'] }), { mode: 'headless' });
  assert.deepEqual(browserStartBody(), { mode: 'headless' });
});

const chooser = { id: 'c1', multiple: false, accept: '.txt', since: 1, max_files: 10, max_file_bytes: 1024 };

test('the file chooser the page opened is followed from ready to answered', () => {
  let state = liveViewReducer(initialLiveViewState, { type: 'ready', control: {}, agent: null, page: null, file_chooser: chooser });
  assert.deepEqual(state.fileChooser, chooser);
  state = liveViewReducer(state, { type: 'file_chooser', chooser: null });
  assert.equal(state.fileChooser, null);
  state = liveViewReducer(state, { type: 'file_chooser', chooser });
  assert.equal(liveViewReducer(state, { type: 'file_upload', status: 'progress', received: 1, total: 2 }), state);
  assert.equal(liveViewReducer(state, { type: 'file_upload', status: 'failed', code: 'too_large', message: 'a.txt is larger than 1 KB' }).error, 'a.txt is larger than 1 KB');
  assert.equal(liveViewReducer(state, { type: 'reset' }).fileChooser, null);
});

test('chosen files are checked against what the page and the sidecar take before any is sent', () => {
  const file = (name, size) => ({ name, size });
  assert.deepEqual(uploadPlan([file('a.txt', 3)], chooser), { files: [{ name: 'a.txt', size: 3 }], total: 3 });
  assert.equal(uploadPlan([file('a.txt', 3), file('b.txt', 3)], chooser).error, 'This field takes one file.');
  assert.deepEqual(uploadPlan([file('a.txt', 3), file('b.txt', 4)], { ...chooser, multiple: true }).total, 7);
  assert.equal(uploadPlan([file('a', 1), file('b', 1)], { ...chooser, multiple: true, max_files: 1 }).error, 'This field takes one file.');
  assert.equal(uploadPlan(Array.from({ length: 3 }, (_, i) => file(`${i}`, 1)), { ...chooser, multiple: true, max_files: 2 }).error, 'This field takes at most 2 files.');
  assert.equal(uploadPlan([file('big.bin', 2048)], chooser).error, 'big.bin is larger than 1 KB.');
  assert.equal(uploadPlan([], chooser).error, 'Choose a file to upload.');
  assert.equal(uploadPlan([file('a', 1)], null).error, 'The page is no longer asking for a file.');
});

test('a chunk is base64 of its bytes, at the size the sidecar takes', () => {
  assert.equal(UPLOAD_CHUNK_BYTES, 32 * 1024);
  assert.equal(encodeChunk(new TextEncoder().encode('hello world')), 'aGVsbG8gd29ybGQ=');
  const large = new Uint8Array(UPLOAD_CHUNK_BYTES).map((_, i) => i % 256);
  assert.deepEqual(Uint8Array.from(atob(encodeChunk(large)), (c) => c.charCodeAt(0)), large);
  assert.equal(uploadProgressLabel({ sent: 512, total: 2048 }), 'Uploading 2 KB… 25%');
  assert.equal(uploadProgressLabel({ sent: 0, total: 0 }), 'Uploading 0 bytes… 100%');
  assert.equal(uploadProgressLabel(null), null);
});

test('viewers who are not driving are told the page waits for a file', () => {
  const waiting = { ...initialLiveViewState, fileChooser: chooser };
  assert.equal(fileChooserWaitLabel({ ...waiting, control: { held: true, mine: false, yours: false, by: 'Ada' } }), 'The page is asking Ada for a file.');
  assert.match(fileChooserWaitLabel({ ...waiting, control: { held: true, mine: false, yours: true, by: 'Ada' } }), /view you are driving from/);
  assert.equal(fileChooserWaitLabel({ ...waiting, control: { held: true, mine: true, yours: true, by: 'Ada' } }), null);
  assert.equal(fileChooserWaitLabel(initialLiveViewState), null);
});
