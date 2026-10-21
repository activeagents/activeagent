import { copyToClipboard } from './clipboard.mjs';

// Where a scenario run's report is exported from, given its in-app report
// route ("/evaluations/3/runs/12/report"): the API path that serves the page
// (`report`), its Markdown (`markdown`), and a download of each format. The
// paths are mount-relative, like the route; null for no route.
export function reportExports(reportPath) {
  if (!reportPath) return null;
  const report = `/api${reportPath}`;
  return {
    report,
    markdown: `${report}.md`,
    html: `${report}?download=1`,
    json: `${report}.json?download=1`,
    md: `${report}.md?download=1`,
  };
}

// One piece of the Markdown report: `part` is verdict, fix_items (narrowed
// by `model`) or scenario (named by `scenario`); none is the whole report.
export function markdownPartUrl(markdownUrl, { part = null, model = null, scenario = null } = {}) {
  if (!markdownUrl) return null;
  const params = new URLSearchParams();
  if (part) params.set('part', part);
  if (model && model !== 'all') params.set('model', model);
  if (scenario) params.set('scenario', scenario);
  const query = params.toString();
  return query ? `${markdownUrl}?${query}` : markdownUrl;
}

// Fetches Markdown from `url` onto the clipboard. Where the page has
// ClipboardItem, the clipboard write starts in the click itself with the
// fetch as its pending content, which Safari requires; otherwise the text
// is fetched first and copied as copyToClipboard does. Resolves true when
// something copied, false when nothing could; never throws.
export async function copyMarkdownFrom(url, {
  fetch: fetchImpl = globalThis.fetch, navigator: nav = globalThis.navigator, document: doc = globalThis.document,
  ClipboardItem: Item = globalThis.ClipboardItem, Blob: BlobImpl = globalThis.Blob,
} = {}) {
  if (!url || typeof fetchImpl !== 'function') return false;
  const text = () => fetchImpl(url, { headers: { Accept: 'text/markdown' }, credentials: 'same-origin' }).then((response) => {
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.text();
  });

  if (Item && BlobImpl && nav?.clipboard?.write) {
    try {
      const pending = text();
      await nav.clipboard.write([new Item({ 'text/plain': pending.then((value) => new BlobImpl([value], { type: 'text/plain' })) })]);
      return true;
    } catch {
      // Fall through to fetching first.
    }
  }
  try {
    return await copyToClipboard(await text(), { navigator: nav, document: doc });
  } catch {
    return false;
  }
}
