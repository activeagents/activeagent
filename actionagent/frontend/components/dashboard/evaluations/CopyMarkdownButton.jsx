import React, { useEffect, useRef, useState } from 'react';
import { Button } from '../primitives';
import { copyToClipboard } from '../../../utils/clipboard.mjs';
import { copyMarkdownFrom } from '../../../utils/reportExport.mjs';

// "Copy as Markdown" for a piece of a run's report — the whole report, the
// verdict, What to fix, a fix card, a scenario — so it can be pasted into an
// issue or a pull request. The Markdown is the server's
// (ActiveAgent::Evals::ReportMarkdown): `text` when the payload already
// carries it, else fetched from `url` when clicked. The label says what
// happened for two seconds, then returns.
export default function CopyMarkdownButton({ text = null, url = null, label = 'Copy as Markdown', title, testId = 'copy-markdown', style }) {
  const [state, setState] = useState('idle');
  const timer = useRef(null);

  useEffect(() => () => clearTimeout(timer.current), []);

  if (!text && !url) return null;

  const copy = async (event) => {
    event?.stopPropagation?.();
    const copied = text ? await copyToClipboard(text) : await copyMarkdownFrom(url);
    setState(copied ? 'copied' : 'failed');
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setState('idle'), 2000);
  };

  return (
    <Button
      size="sm"
      variant="ghost"
      onClick={copy}
      testId={testId}
      title={title || 'Copy as GitHub-flavored Markdown, for an issue or a pull request'}
      style={{ padding: '4px 8px', fontSize: 12, color: state === 'failed' ? 'var(--color-error)' : state === 'copied' ? 'var(--color-success-text)' : 'var(--color-text-secondary)', ...style }}
    >
      {state === 'copied' ? 'Copied' : state === 'failed' ? 'Copy failed' : label}
    </Button>
  );
}
