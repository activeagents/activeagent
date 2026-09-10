import React from 'react';
import GenerativeUI from './GenerativeUI';
import { uiFenceBlocks } from '../../utils/generativeUi';

// Minimal, safe markdown renderer for agent message content: headings,
// bold/italic, inline code, fenced code blocks, links, and lists. Renders
// React elements only (no innerHTML), so untrusted model output stays inert.
//
// A fenced ```ui block (or ```json-ui / ```genui) whose body is JSON renders
// as generative UI in place; `onUiAction` receives form submissions and
// choice clicks from those blocks. An invalid body stays a code block.

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

const isTableRow = (line) => /^\s*\|.*\|\s*$/.test(line);
const isTableSeparator = (line) => /^\s*\|(\s*:?-+:?\s*\|)+\s*$/.test(line);
// Cells between the outer pipes; an escaped \| inside a cell stays a pipe.
const splitTableRow = (line) =>
  line.trim().replace(/^\|/, '').replace(/\|$/, '').split(/(?<!\\)\|/).map((cell) => cell.replace(/\\\|/g, '|').trim());

export default function Markdown({ text, onUiAction, darkMode }) {
  if (!text) return null;

  const blocks = [];
  const lines = String(text).split('\n');
  let i = 0;
  let key = 0;

  while (i < lines.length) {
    const line = lines[i];

    if (line.startsWith('```')) {
      const lang = line.slice(3).trim();
      const code = [];
      i += 1;
      while (i < lines.length && !lines[i].startsWith('```')) {
        code.push(lines[i]);
        i += 1;
      }
      const closed = i < lines.length;
      i += 1;
      const uiBlocks = closed ? uiFenceBlocks(lang, code.join('\n')) : null;
      if (uiBlocks) {
        blocks.push(
          <div key={key++} className="my-2">
            <GenerativeUI blocks={uiBlocks} onAction={onUiAction} darkMode={darkMode} />
          </div>
        );
        continue;
      }
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

    // GFM pipe table: a header row, a |---| separator, then body rows.
    // Models answer comparisons with these constantly, and as raw text a
    // four-column table is unreadable.
    if (isTableRow(line) && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
      const header = splitTableRow(line);
      i += 2;
      const rows = [];
      while (i < lines.length && isTableRow(lines[i])) {
        rows.push(splitTableRow(lines[i]));
        i += 1;
      }
      const tableKey = key++;
      blocks.push(
        <div key={tableKey} className="overflow-x-auto my-1">
          <table className="text-[0.95em]" style={{ borderCollapse: 'collapse', minWidth: '50%' }}>
            <thead>
              <tr>
                {header.map((cell, c) => (
                  <th
                    key={c}
                    className="text-left font-semibold px-2 py-1"
                    style={{ borderBottom: '1px solid rgba(127,127,127,0.35)' }}
                  >
                    {renderInline(cell, `th${tableKey}-${c}`)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((cells, r) => (
                <tr key={r}>
                  {header.map((_, c) => (
                    <td key={c} className="px-2 py-1 align-top" style={{ borderBottom: '1px solid rgba(127,127,127,0.15)' }}>
                      {renderInline(cells[c] ?? '', `td${tableKey}-${r}-${c}`)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
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
