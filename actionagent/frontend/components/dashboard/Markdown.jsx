import React from 'react';

// Minimal, safe markdown renderer for agent message content: headings,
// bold/italic, inline code, fenced code blocks, links, and lists. Renders
// React elements only (no innerHTML), so untrusted model output stays inert.

const INLINE_PATTERN = /(\*\*[^*]+\*\*|\*[^*\n]+\*|`[^`]+`|\[[^\]]+\]\((?:https?:\/\/|\/)[^)\s]+\))/g;

const renderInline = (text, keyPrefix) =>
  text.split(INLINE_PATTERN).filter(Boolean).map((part, i) => {
    const key = `${keyPrefix}-${i}`;
    if (part.startsWith('**') && part.endsWith('**')) {
      return <strong key={key}>{part.slice(2, -2)}</strong>;
    }
    if (part.startsWith('*') && part.endsWith('*') && part.length > 2) {
      return <em key={key}>{part.slice(1, -1)}</em>;
    }
    if (part.startsWith('`') && part.endsWith('`')) {
      return (
        <code key={key} className="px-1 py-0.5 rounded text-[0.9em]" style={{ background: 'rgba(127,127,127,0.15)' }}>
          {part.slice(1, -1)}
        </code>
      );
    }
    const link = part.match(/^\[([^\]]+)\]\(((?:https?:\/\/|\/)[^)\s]+)\)$/);
    if (link) {
      return (
        <a key={key} href={link[2]} target="_blank" rel="noopener noreferrer" className="underline text-blue-500">
          {link[1]}
        </a>
      );
    }
    return part;
  });

export default function Markdown({ text }) {
  if (!text) return null;

  const blocks = [];
  const lines = String(text).split('\n');
  let i = 0;
  let key = 0;

  while (i < lines.length) {
    const line = lines[i];

    if (line.startsWith('```')) {
      const code = [];
      i += 1;
      while (i < lines.length && !lines[i].startsWith('```')) {
        code.push(lines[i]);
        i += 1;
      }
      i += 1;
      blocks.push(
        <pre
          key={key++}
          className="rounded-md px-3 py-2 text-[0.85em] overflow-x-auto my-1"
          style={{ background: 'rgba(127,127,127,0.12)' }}
        >
          {code.join('\n')}
        </pre>
      );
      continue;
    }

    const heading = line.match(/^(#{1,4})\s+(.*)$/);
    if (heading) {
      blocks.push(
        <div key={key++} className="font-semibold mt-1" style={{ fontSize: `${1.25 - heading[1].length * 0.05}em` }}>
          {renderInline(heading[2], `h${key}`)}
        </div>
      );
      i += 1;
      continue;
    }

    if (/^\s*([-*]|\d+\.)\s+/.test(line)) {
      const items = [];
      while (i < lines.length && /^\s*([-*]|\d+\.)\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\s*([-*]|\d+\.)\s+/, ''));
        i += 1;
      }
      blocks.push(
        <ul key={key++} className="list-disc pl-5 my-0.5">
          {items.map((item, j) => <li key={j}>{renderInline(item, `li${key}-${j}`)}</li>)}
        </ul>
      );
      continue;
    }

    if (line.trim() === '') {
      blocks.push(<div key={key++} className="h-2" />);
      i += 1;
      continue;
    }

    blocks.push(<div key={key++}>{renderInline(line, `p${key}`)}</div>);
    i += 1;
  }

  return <div className="break-words">{blocks}</div>;
}
