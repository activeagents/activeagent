import React, { useEffect, useRef, useState } from 'react';
import { Button } from '../primitives';
import { copyToClipboard } from '../../../utils/clipboard.mjs';

// One click puts a fix card's Markdown brief on the clipboard, ready to
// paste into a coding harness. `build` composes the text when clicked, so
// a list of cards never renders prompts nobody copies. The label says what
// happened for two seconds, then returns.
export default function CopyFixPromptButton({ build, testId = 'copy-fix-prompt', style }) {
  const [state, setState] = useState('idle');
  const timer = useRef(null);

  useEffect(() => () => clearTimeout(timer.current), []);

  const copy = async () => {
    let text = '';
    try {
      text = build?.() || '';
    } catch {
      text = '';
    }
    const copied = text ? await copyToClipboard(text) : false;
    setState(copied ? 'copied' : 'failed');
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setState('idle'), 2000);
  };

  const label = state === 'copied' ? 'Copied' : state === 'failed' ? 'Copy failed' : 'Copy fix prompt';
  return (
    <Button
      size="sm"
      variant="ghost"
      onClick={copy}
      testId={testId}
      title="Copy a Markdown brief of this fix — the scenarios, what they expect, what the agent did, and how to verify — for your coding harness"
      style={{ padding: '4px 8px', fontSize: 12, color: state === 'failed' ? 'var(--color-error)' : state === 'copied' ? 'var(--color-success-text)' : 'var(--color-text-secondary)', ...style }}
    >
      {label}
    </Button>
  );
}

// The mounted dashboard's absolute URL for the briefs' links, or '' outside
// a browser.
export const dashboardUrl = () => {
  if (typeof window === 'undefined' || !window.location) return '';
  const mount = String(window.ACTIVE_AGENT_DASHBOARD?.mountPath || '').replace(/\/+$/, '');
  return `${window.location.origin}${mount}`;
};
