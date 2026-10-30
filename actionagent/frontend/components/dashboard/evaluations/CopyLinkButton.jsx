import React from 'react';
import CopyMarkdownButton from './CopyMarkdownButton';
import { evaluationLinkPath, shareableUrl } from '../../../utils/evaluationLinks.mjs';

// "Copy link" for an evaluation, a run or one scenario result: the absolute
// URL a teammate in the same account opens to land on the same view. Same
// button and feedback as the Markdown copies; renders nothing when the ids
// do not make a link.
export default function CopyLinkButton({ evaluationId, runId = null, resultId = null, label = 'Copy link', title, testId = 'copy-link', style }) {
  const path = evaluationLinkPath({ evaluationId, runId, resultId });
  if (!path) return null;
  const url = shareableUrl(path, {
    origin: typeof window !== 'undefined' ? window.location?.origin : '',
    mountPath: typeof window !== 'undefined' ? window.ACTIVE_AGENT_DASHBOARD?.mountPath : '',
  });
  return (
    <CopyMarkdownButton
      text={url}
      label={label}
      testId={testId}
      title={title || 'Copy a link to this view, for a teammate in your organization'}
      style={style}
    />
  );
}
