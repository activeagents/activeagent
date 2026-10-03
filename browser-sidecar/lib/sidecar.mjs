import { mkdtemp, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { startEgressProxy } from './egress-proxy.mjs';
import { acceptedHosts } from './guard.mjs';
import { createHttpServer } from './http-server.mjs';
import { McpGateway } from './mcp-gateway.mjs';
import { NavigationGuard } from './navigation-guard.mjs';
import { NetworkPolicy } from './network-policy.mjs';
import { PAGE_FLUSH_MS, Recorder } from './recorder.mjs';
import { exportStorageState } from './storage-state.mjs';
import { VERSION } from './version.mjs';

const VIEWPORT = { width: 1280, height: 800 };
// WebRTC sends UDP around the proxy unless told otherwise. The headless
// shell reads the first switch and headed Chromium the second.
const WEBRTC_PROXIED_ONLY = ['--force-webrtc-ip-handling-policy=disable_non_proxied_udp', '--webrtc-ip-handling-policy=disable_non_proxied_udp'];
// How long shutting down waits for the last recording batches to post.
const RECORDING_DRAIN_MS = 5000;

/**
 * Checks every request and WebSocket the context's pages open against
 * `policy.allows`, by URL, before it is sent. Registered once on the
 * context, so it holds whichever MCP session drives the browser. Playwright
 * calls a route only for the first URL of a redirect chain; the egress proxy
 * and the NavigationGuard cover the hops after it.
 *
 * @param {import('playwright').BrowserContext} context
 * @param {NetworkPolicy} policy
 */
export async function installNetworkPolicy(context, policy) {
  await context.route('**/*', async (route) => {
    const request = route.request();
    let topLevelNavigation = false;
    try {
      topLevelNavigation = request.isNavigationRequest() && request.frame().parentFrame() === null;
    } catch {
      // A request without a frame (a worker's) is not a navigation.
    }

    try {
      if (policy.allows(request.url(), { topLevelNavigation })) await route.fallback();
      else await route.abort('blockedbyclient');
    } catch {
      // The page went away while the request was decided.
    }
  });

  await context.routeWebSocket(/.*/, async (socket) => {
    if (policy.allows(socket.url())) socket.connectToServer();
    else await socket.close({ code: 1008, reason: 'Blocked by the sandbox browser' }).catch(() => {});
  });
}

async function launchChromium(userDataDir, options) {
  const { chromium } = await import('playwright');
  return chromium.launchPersistentContext(userDataDir, options);
}

// Calls `callback` at `time` (epoch ms). setTimeout fires at once for a delay
// past 2^31 - 1 ms, so a far deadline is reached in steps.
function stopAt(time, callback) {
  const delay = time - Date.now();
  if (delay <= 0) return callback();
  setTimeout(() => stopAt(time, callback), Math.min(delay, 2 ** 31 - 1));
}

/**
 * The Playwright MCP configuration every session's server runs with.
 *
 * @param {{ capabilities: string[] }} config
 * @param {string} outputDir
 */
export function mcpConfig(config, outputDir) {
  return {
    browser: { browserName: 'chromium', isolated: false },
    capabilities: config.capabilities,
    // Makes browser_close refuse to close the context the sessions share.
    sharedBrowserContext: true,
    // Pages would otherwise add tools of their own to the agent's list.
    webmcp: false,
    outputDir,
    filePaths: 'absolute',
    codegen: 'none',
    timeouts: { idle: 0 },
  };
}

/**
 * Starts the browser and its MCP endpoint, and returns once the endpoint
 * listens. Chromium gets a fresh profile directory and is driven over a pipe
 * (Playwright's --remote-debugging-pipe), so no debugging port is opened.
 * Every connection it makes goes through the egress proxy, loopback and
 * WebRTC included. The process's working directory becomes an empty uploads
 * directory, which is where Playwright MCP reads files to upload from.
 *
 * @param {object} config a parsed configuration (see parseConfig)
 * @param {object} [dependencies]
 * @param {Function} [dependencies.launch] chromium.launchPersistentContext
 * @param {Function} [dependencies.createConnection] @playwright/mcp's createConnection
 * @param {NetworkPolicy} [dependencies.policy] the rules for what the browser may load
 * @param {(message: string) => void} [dependencies.log]
 * @returns {Promise<{ port: number, close: (reason?: string, code?: number) => Promise<number>, done: Promise<number> }>}
 *   `close` stops everything and removes the directories; `done` settles with
 *   the exit status once it has, whatever stopped it (0, or 1 when the
 *   browser went away on its own)
 */
export async function startSidecar(config, dependencies = {}) {
  const log = dependencies.log ?? ((message) => process.stderr.write(`browser-sidecar: ${message}\n`));
  const launch = dependencies.launch ?? launchChromium;
  const connect = dependencies.createConnection ?? (await import('@playwright/mcp')).createConnection;

  const ownsWorkdir = config.workdir === null;
  const workdir = config.workdir ?? (await mkdtemp(join(tmpdir(), 'activeagents-browser-')));
  const profileDir = await mkdtemp(join(workdir, 'profile-'));
  const uploadsDir = await mkdtemp(join(workdir, 'uploads-'));
  const outputDir = await mkdtemp(join(workdir, 'output-'));
  const removeDirectories = async () => {
    for (const dir of ownsWorkdir ? [workdir] : [profileDir, uploadsDir, outputDir]) {
      await rm(dir, { recursive: true, force: true }).catch(() => {});
    }
  };
  process.chdir(uploadsDir);

  const policy = dependencies.policy ?? new NetworkPolicy({ appOrigin: config.appOrigin });
  const proxy = await startEgressProxy({ policy, log });
  let context;
  try {
    context = await launch(profileDir, {
      headless: config.mode === 'headless',
      viewport: VIEWPORT,
      serviceWorkers: 'block',
      // Chromium sends loopback requests around a proxy unless the bypass
      // list names <-loopback>. Playwright adds it unless
      // PLAYWRIGHT_DISABLE_FORCED_CHROMIUM_PROXIED_LOOPBACK is set; naming it
      // here keeps it either way.
      proxy: { server: proxy.url, bypass: '<-loopback>' },
      args: WEBRTC_PROXIED_ONLY,
      chromiumSandbox: config.chromiumSandbox,
      handleSIGINT: false,
      handleSIGTERM: false,
      handleSIGHUP: false,
    });
  } catch (error) {
    await proxy.close();
    await removeDirectories();
    throw error;
  }

  await installNetworkPolicy(context, policy);
  if (config.storageState) await context.setStorageState(config.storageState);
  const guard = new NavigationGuard({ policy, log });
  guard.attach(context);
  const recorder = config.recording ? new Recorder({ recording: config.recording, log }) : null;
  await recorder?.attach(context);

  const gateway = new McpGateway({
    connect: () => connect(mcpConfig(config, outputDir), async () => context),
    policy,
    guard,
    snapshotDir: await realpath(outputDir),
  });
  let hosts = new Set();
  const server = createHttpServer({
    rules: () => ({ token: config.token, hosts }),
    gateway,
    version: VERSION,
    storageState: () => exportStorageState(context, config.appOrigin),
  });

  let closing = null;
  let finished;
  const done = new Promise((resolve) => {
    finished = resolve;
  });
  // The first reason to stop decides the exit status: closing the context
  // here fires its close event too.
  const close = (reason, exitCode = 0) => {
    closing ??= (async () => {
      if (reason) log(`stopping: ${reason}`);
      server.close();
      server.closeAllConnections();
      await gateway.closeAll();
      // The pages hand over the rrweb events they hold, then the context
      // closes before the recorder, so the recording gets the closing markers.
      if (recorder) await new Promise((resolve) => setTimeout(resolve, PAGE_FLUSH_MS * 2));
      await context.close().catch(() => {});
      await proxy.close();
      await recorder?.close(RECORDING_DRAIN_MS);
      await removeDirectories();
      finished(exitCode);
      return exitCode;
    })();
    return closing;
  };
  context.on('close', () => void close('the browser closed', 1));

  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(config.port, config.host, resolve);
    });
  } catch (error) {
    await close();
    throw error;
  }
  const { port } = server.address();
  hosts = acceptedHosts(config.host, port, config.allowedHosts);

  if (config.stopAt !== null) stopAt(config.stopAt, () => void close('the sandbox expired'));

  // The first page opens on the app, so the recording starts there.
  const [page] = context.pages();
  page?.goto(config.appOrigin).catch((error) => log(`could not open ${config.appOrigin}: ${error.message}`));

  return { port, close, done };
}
