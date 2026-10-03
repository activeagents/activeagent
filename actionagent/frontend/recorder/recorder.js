// The session recorder: rrweb's record, built as its own module
// (action_agent_recorder.js) so the dashboard's bundle carries no rrweb code.
// The dashboard imports it while the Run Agent workbench is open, from the
// URL the dashboard page names (utils/sessionCapture.mjs drives it).
export { record } from '@rrweb/record';
