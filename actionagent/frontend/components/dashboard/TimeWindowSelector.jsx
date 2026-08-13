import React from 'react';
import { useTimeWindow } from '../../contexts/TimeWindowContext';
import { useTheme } from '../../contexts/ThemeContext';
import { paletteFor } from '../../utils/dashboardTheme';

// The dashboard-wide period control. Rendered by every view that shows
// time-bounded data so the selection reads the same and stays put as you
// navigate — including inside the agent page's themed panels, which is why it
// resolves the palette rather than assuming a light surface.
export default function TimeWindowSelector({ compact = false }) {
  const { windows, windowIndex, timeWindow, setWindow, zoomTo } = useTimeWindow();
  const { darkMode } = useTheme();
  const colors = paletteFor(darkMode);

  const zoomStyle = { color: colors.textSecondary };

  return (
    <div className="flex items-center rounded-lg p-1" style={{ background: colors.mutedBg }}>
      <button
        onClick={() => zoomTo(windowIndex - 1)}
        disabled={windowIndex <= 0}
        title="Zoom in (shorter window)"
        aria-label="Zoom in"
        className="aa-zoom px-2 py-1 text-sm rounded-md disabled:opacity-30 disabled:cursor-not-allowed"
        style={zoomStyle}
      >
        −
      </button>
      <select
        value={timeWindow.id}
        onChange={(e) => setWindow(e.target.value)}
        aria-label="Time window"
        className={`aa-field px-2 py-1 mx-1 text-sm rounded-md shadow ${compact ? '' : 'min-w-[4.5rem]'}`}
        style={{ background: colors.cardBg, color: colors.textPrimary, border: `1px solid ${colors.cardBorder}` }}
      >
        {windows.map((option) => (
          <option key={option.id} value={option.id}>{option.label}</option>
        ))}
      </select>
      <button
        onClick={() => zoomTo(windowIndex + 1)}
        disabled={windowIndex >= windows.length - 1}
        title="Zoom out (longer window)"
        aria-label="Zoom out"
        className="aa-zoom px-2 py-1 text-sm rounded-md disabled:opacity-30 disabled:cursor-not-allowed"
        style={zoomStyle}
      >
        +
      </button>
    </div>
  );
}
