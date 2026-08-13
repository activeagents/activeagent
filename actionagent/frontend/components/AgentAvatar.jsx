import React from 'react';

/**
 * Agent Avatar Component
 *
 * Renders the ActiveAgent mascot (red face, sunglasses, hat) matching
 * the hero SVG from the landing page. Supports decorative overlays
 * for instructions (above) and tools (below) to match the lander's
 * agent builder preview pattern.
 *
 * @example
 * <AgentAvatar size={200} />
 * <AgentAvatar size={120} instructions={['github']} tools={['terminal']} />
 */

// Instruction/tool metadata matching the lander's Stimulus controller
export const INSTRUCTIONS = {
  github: { emoji: '\u{1F419}', label: 'GitHub' },
  ruby: { emoji: '\u{1F48E}', label: 'Ruby' },
  rails: { emoji: '\u{1F6E4}\uFE0F', label: 'Rails' },
  aws: { emoji: '\u2601\uFE0F', label: 'AWS' },
  gcp: { emoji: '\u{1F310}', label: 'GCP' },
  python: { emoji: '\u{1F40D}', label: 'Python' },
  typescript: { emoji: '\u{1F4D8}', label: 'TypeScript' },
  docker: { emoji: '\u{1F433}', label: 'Docker' },
  kubernetes: { emoji: '\u2638\uFE0F', label: 'Kubernetes' },
};

export const TOOLS = {
  terminal: { emoji: '\u{1F4BB}', label: 'Terminal' },
  playwright: { emoji: '\u{1F3AD}', label: 'Playwright' },
  filesystem: { emoji: '\u{1F4C1}', label: 'Filesystem' },
  code: { emoji: '\u{1F468}\u200D\u{1F4BB}', label: 'Code' },
  database: { emoji: '\u{1F5C4}\uFE0F', label: 'Database' },
  slack: { emoji: '\u{1F4AC}', label: 'Slack' },
  fetch: { emoji: '\u{1F310}', label: 'Fetch' },
  search: { emoji: '\u{1F50D}', label: 'Search' },
  edit: { emoji: '\u270F\uFE0F', label: 'Edit' },
  translate: { emoji: '\u{1F30D}', label: 'Translate' },
  memory: { emoji: '\u{1F9E0}', label: 'Memory' },
};

// Preset configurations matching the lander's agent builder presets
export const AGENT_PRESETS = {
  terminal: { instructions: ['github'], tools: ['terminal', 'code'] },
  webDeveloper: { instructions: ['typescript'], tools: ['playwright', 'fetch'] },
  documentAnalysis: { instructions: ['python'], tools: ['database', 'search', 'code'] },
  writing: { instructions: ['ruby'], tools: ['edit', 'memory'] },
  translation: { instructions: ['ruby', 'python', 'typescript'], tools: ['translate', 'code'] },
  playwright: { instructions: ['typescript'], tools: ['playwright', 'fetch'] },
  research: { instructions: ['github'], tools: ['fetch', 'search', 'memory'] },
  imageAnalysis: { instructions: ['python'], tools: ['filesystem', 'code'] },
  computerUse: { instructions: ['github'], tools: ['terminal', 'playwright'] },
  productDesign: { instructions: ['typescript'], tools: ['playwright', 'code'] },
};

// Keep legacy theme exports for any existing references
export const AGENT_THEMES = {
  default: { primary: '#EB5555', secondary: '#D43B3B', highlight: '#FF6B6B' },
  terminal: { primary: '#EB5555', secondary: '#D43B3B', highlight: '#FF6B6B' },
  research: { primary: '#EB5555', secondary: '#D43B3B', highlight: '#FF6B6B' },
  translation: { primary: '#EB5555', secondary: '#D43B3B', highlight: '#FF6B6B' },
  writing: { primary: '#EB5555', secondary: '#D43B3B', highlight: '#FF6B6B' },
};

/**
 * The core mascot SVG - matches activeagent-hero.svg from the landing page.
 * Red pentagon face, black hat, sunglasses with eyes behind them.
 */
const MascotSVG = ({ id = 'mascot' }) => (
  <g stroke="none" fill="none" fillRule="evenodd" strokeWidth="1">
    <g transform="translate(25, 475) scale(-1, 1) rotate(-180) translate(-25, -475) translate(0, 450)">
      {/* Face */}
      <g fillRule="nonzero">
        <path
          d="M421,271.3 C422.733,265.1 423.667,244.633 423.8,209.9 C423.9,173.4 423.8,142.1 423.5,140.4 C423.1,137.9 412.5,126.8 373.1,87.2 C345.6,59.7 321.7,36.3 319.8,35.3 C316.7,33.6 312.5,33.5 250,33.5 C186.5,33.5 183.3,33.6 178.2,35.4 C173.5,37.2 168.3,42.1 125.2,85.3 C69.3,141.4 75.6,134.9 73.7,138.7 C72.3,141.3 72,147.2 71.8,178.6 C71.3,243.6 71.8,276 73.4,276 C74.067,276 99.6,304.854 150,362.563 L350.015,362.563 L421,271.3 Z"
          fill="#EB5555"
          stroke="#000000"
          strokeWidth="12"
        />
      </g>
      {/* Mouth */}
      <path d="M216.5,202.5 C213.4,199.5 213.4,198.7 216.5,193.4 C223.2,182 248.2,176 264.5,181.9 C273,185 280.3,190.1 282.4,194.5 C284,197.9 284,198.3 282.5,200.6 C281.6,202 279.8,203.6 278.5,204.2 C276.4,205.1 275.4,204.7 270.1,200.8 C263,195.4 254.7,193.3 244.4,194.4 C236.1,195.3 234.3,196 228.6,200.9 C223.1,205.6 220,206.1 216.5,202.5 Z" fill="#000000" fillRule="nonzero" />
      {/* Hat */}
      <path d="M177.8,484.5 C169.1,482.1 162,475.2 157.7,465 C156.2,461.4 151.9,446.6 148.1,432 C144.3,417.4 140.7,404.3 140.1,402.8 L139,400 L94.8,400 C70.4,400 49.5,399.7 48.2,399.4 C45.1,398.5 42.7,393.8 43.9,390.8 C45.1,387.9 49.4,383.3 54,379.9 C68.7,369.2 86.3,364.8 120,363.4 C126.067,363.2 134.065,362.921 143.995,362.563 L350.015,362.563 C367.433,363.767 377.5,364.1 377.5,364.1 C411,365.2 433.1,371.5 446.2,383.8 C453.8,390.9 455.1,394.7 451.3,399 C451,399.3 429.6,399.7 403.7,400 L356.6,400.5 L353.3,412.5 C351.5,419.1 348.2,431.3 346.1,439.5 C339.9,463 336.7,470.5 329.4,477.5 C322.9,483.8 315.7,486.3 305.5,485.8 C298.1,485.4 296.1,484.7 280.5,477.8 C271.2,473.7 261.7,469.7 259.5,468.9 C250.9,466.1 238.1,467.9 224.9,473.8 C197.3,486.1 189.8,487.8 177.8,484.5 Z" stroke="#000000" strokeWidth="11" fill="#000000" fillRule="nonzero" />
      {/* Eyes (behind lenses) */}
      <g transform="translate(75.105, 196.182)">
        <ellipse fill="#F5E6D3" cx="87" cy="55" rx="35" ry="29" />
        <ellipse fill="#5D4037" cx="87" cy="57" rx="20" ry="20" />
        <ellipse fill="#2D1F1F" cx="87" cy="57" rx="12" ry="12" />
        <ellipse fill="#FFFFFF" cx="80" cy="51" rx="5" ry="5" />
        <ellipse fill="#F5E6D3" cx="259" cy="55" rx="35" ry="29" />
        <ellipse fill="#5D4037" cx="259" cy="57" rx="20" ry="20" />
        <ellipse fill="#2D1F1F" cx="259" cy="57" rx="12" ry="12" />
        <ellipse fill="#FFFFFF" cx="252" cy="51" rx="5" ry="5" />
      </g>
      {/* Lenses */}
      <g transform="translate(75.105, 196.182)" fillRule="nonzero">
        <g transform="translate(267.395, 54.835) scale(-1, 1) translate(-267.395, -54.835)">
          <path
            d="M346.895,99.881 L335.287,108.67 L292.495,108.67 L211.805,108.67 C194.861,92.394 186.922,84.257 187.99,84.257 C188.99,84.257 187.689,77.518 187.99,71.118 C188.99,54.518 196.996,38.618 211.805,23.818 C219.711,15.918 222.813,13.518 230.118,10.018 C242.025,4.118 250.431,1.818 262.839,1.118 C274.147,0.518 285.354,2.218 295.561,6.018 C308.67,10.918 327.482,26.818 335.287,39.618 C342.092,50.918 346.895,65.818 346.895,76.018 C346.895,82.818 346.895,90.772 346.895,99.881 Z"
            stroke="#000000" strokeWidth="8" fill="#000000" fillOpacity="0.92"
          />
        </g>
        <path
          d="M158.895,99.881 L147.295,108.67 L104.531,108.67 L23.895,108.67 C6.961,92.394 -0.972,84.257 0.095,84.257 C1.095,84.257 -0.205,77.518 0.095,71.118 C1.095,54.518 9.095,38.618 23.895,23.818 C31.795,15.918 34.895,13.518 42.195,10.018 C54.095,4.118 62.495,1.818 74.895,1.118 C86.195,0.518 97.395,2.218 107.595,6.018 C120.695,10.918 139.495,26.818 147.295,39.618 C154.095,50.918 158.895,65.818 158.895,76.018 C158.895,82.818 158.895,90.772 158.895,99.881 Z"
          stroke="#000000" strokeWidth="8" fill="#000000" fillOpacity="0.92"
        />
      </g>
      {/* Frames */}
      <g transform="translate(75.105, 196.182)" fillRule="nonzero">
        <path
          d="M187.895,73.418 C187.895,60.818 195.095,43.418 205.495,30.818 C213.379,21.259 220.29,15.351 230.066,10.615 C233.275,8.66 236.386,7.08 239.229,6.018 C246.892,3.165 255.119,1.496 263.529,1.095 C267.063,0.859 270.58,0.912 274.131,1.261 C285.374,2.105 293.475,4.47 304.672,10.018 C311.734,13.402 314.868,15.757 322.213,23.049 L322.795,23.618 C326.306,27.085 329.397,30.586 332.082,34.15 L332.148,34.235 C341.116,45.994 346.03,58.349 346.8,71.118 C346.957,74.467 346.676,77.909 346.515,80.429 C346.693,80.646 346.917,80.701 347.195,80.618 C347.366,80.542 348.039,80.501 349.213,80.495 L349.775,80.495 C352.888,80.507 358.769,80.715 367.418,81.118 C374.646,86.469 378.26,91.703 378.26,96.818 C378.26,101.933 374.646,107.042 367.418,112.146 L15.403,112.146 L-20.38,113.348 C-27.807,110.322 -31.52,105.629 -31.52,99.27 C-31.52,92.911 -27.807,88.087 -20.38,84.798 C-13.63,84.605 -8.537,84.463 -5.101,84.373 C-5.115,84.296 -5.084,84.257 -5.01,84.257 C-4.01,84.257 -5.311,77.518 -5.01,71.118 C-4.01,54.518 3.996,38.618 18.805,23.818 C26.711,15.918 29.813,13.518 37.118,10.018 C49.025,4.118 57.431,1.818 69.839,1.118 C72.166,0.994 74.489,0.968 76.8,1.038 C76.165,1.058 75.53,1.084 74.895,1.118 C62.495,1.818 54.095,4.118 42.195,10.018 C34.895,13.518 31.795,15.918 23.895,23.818 C9.095,38.618 1.095,54.518 0.095,71.118 C-0.205,77.518 1.095,84.257 0.095,84.257 C-0.4,84.257 -2.131,84.296 -5.101,84.373 C-4.938,85.42 3.031,93.518 18.805,108.67 L142.287,108.67 L153.895,99.881 L153.895,76.018 C153.895,65.818 149.092,50.918 142.287,39.618 C134.482,26.818 115.67,10.918 102.561,6.018 C94.455,3 85.717,1.307 76.8,1.038 C87.451,0.716 97.968,2.432 107.595,6.018 C120.695,10.918 139.495,26.818 147.295,39.618 C154.095,50.918 158.895,65.818 158.895,76.018 L158.895,80.418 L164.995,80.418 C168.395,80.118 174.995,79.818 179.495,79.818 L187.895,79.818 L187.895,99.881 L199.502,108.67 L322.984,108.67 C339.929,92.394 347.867,84.257 346.8,84.257 C346.323,84.257 346.369,82.725 346.515,80.429 C346.051,79.868 345.895,78.223 345.895,75.118 C345.895,59.873 341.479,46.625 332.082,34.15 L331.696,33.647 C329.117,30.321 326.212,27.043 322.984,23.818 C322.722,23.556 322.465,23.299 322.213,23.049 C316.441,17.437 312.579,14.708 306.095,11.418 C294.424,5.583 284.144,2.245 274.131,1.261 C273.417,1.207 272.691,1.16 271.95,1.118 C269.132,0.968 266.321,0.962 263.529,1.095 C257.389,1.506 251.198,2.792 244.695,4.918 C239.073,6.731 234.301,8.563 230.066,10.615 C218.478,17.668 205.615,29.594 199.502,39.618 C192.698,50.917 187.895,65.817 187.895,76.017 L187.895,73.418 Z"
          stroke="#000000" strokeWidth="8" fill="#000000"
        />
      </g>
      {/* Sparkles */}
      <g transform="translate(83.563, 252.212)" fill="#FFFFFF" fillRule="nonzero">
        <path d="M12.837,35.288 C13.137,33.988 14.437,31.888 15.637,30.788 L17.837,28.788 L15.637,26.788 C14.437,25.688 13.137,23.588 12.837,22.288 C12.037,19.088 10.637,19.088 9.437,22.188 C8.937,23.488 7.537,25.588 6.237,26.788 C4.037,28.788 4.037,28.988 5.737,29.988 C6.837,30.488 8.237,32.488 9.037,34.388 C10.737,38.388 11.937,38.688 12.837,35.288 Z M29.237,33.088 C30.137,29.688 31.837,27.088 34.937,24.088 L39.337,19.888 L36.337,17.788 C33.437,15.588 28.437,7.288 28.437,4.288 C28.437,2.188 26.537,2.388 25.837,4.588 C23.937,10.388 21.637,14.388 18.337,17.188 L14.537,20.388 L17.337,22.088 C19.837,23.588 24.337,30.988 25.837,36.088 C26.737,39.088 27.937,37.988 29.237,33.088 Z M10.937,12.488 L13.037,9.288 L10.937,6.088 C8.837,2.788 7.437,1.888 7.437,3.988 C7.437,4.588 6.537,6.088 5.437,7.288 L3.437,9.488 L5.437,11.288 C6.537,12.288 7.437,13.688 7.437,14.488 C7.437,16.688 8.837,15.888 10.937,12.488 Z" />
        <path d="M203.437,36.388 C203.437,35.588 204.637,33.588 206.037,31.888 L208.637,28.788 L206.037,25.688 C204.637,23.988 203.437,21.988 203.437,21.188 C203.437,18.588 201.437,19.788 200.037,23.188 C199.237,25.088 197.837,27.088 196.737,27.688 C195.037,28.688 195.037,28.788 197.037,30.188 C198.237,30.988 199.737,33.088 200.437,34.788 C201.737,37.888 203.437,38.788 203.437,36.388 Z M220.837,32.588 C221.937,29.288 224.237,25.788 226.737,23.388 C229.737,20.488 230.537,19.288 229.437,18.988 C226.637,17.988 222.437,12.588 220.737,7.688 C219.737,4.988 218.737,2.788 218.337,2.788 C218.037,2.788 216.737,5.288 215.537,8.288 C214.337,11.288 211.737,15.088 209.837,16.688 C205.937,20.188 205.637,21.388 208.437,22.288 C210.937,23.088 214.737,28.788 216.437,34.088 C217.037,36.088 217.937,37.788 218.237,37.788 C218.637,37.788 219.837,35.388 220.837,32.588 Z M201.137,14.088 C201.437,13.088 202.437,11.488 203.337,10.488 C204.337,9.288 204.537,8.388 203.837,7.988 C203.237,7.588 202.237,6.288 201.537,5.088 C200.137,2.388 198.837,2.188 198.037,4.588 C197.737,5.488 196.937,6.988 196.337,7.888 C195.337,9.288 195.437,9.888 196.737,11.288 C197.637,12.188 198.437,13.588 198.437,14.388 C198.437,16.388 200.337,16.188 201.137,14.088 Z" />
      </g>
    </g>
  </g>
);

/**
 * AgentAvatar - Renders the ActiveAgent mascot matching the landing page design
 *
 * @param {number} size - Size in pixels (default: 200)
 * @param {string[]} instructions - Array of instruction IDs to show above
 * @param {string[]} tools - Array of tool IDs to show below
 * @param {boolean} showDecorations - Whether to show instruction/tool badges
 * @param {string} className - Additional CSS classes
 */
export default function AgentAvatar({
  size = 200,
  instructions = [],
  tools = [],
  showDecorations = false,
  className = '',
  // Legacy props (kept for backward compatibility)
  hat,
  hatAccessory,
  heldItem,
  theme,
  customColors,
}) {
  return (
    <div className={`inline-flex flex-col items-center ${className}`}>
      {showDecorations && instructions.length > 0 && (
        <div className="flex gap-1 mb-1">
          {instructions.map(id => {
            const instr = INSTRUCTIONS[id];
            return instr ? (
              <span key={id} className="text-sm" title={instr.label}>{instr.emoji}</span>
            ) : null;
          })}
        </div>
      )}
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 500 500"
        width={size}
        height={size}
        role="img"
        aria-label="Active Agent mascot"
      >
        <title>ActiveAgent</title>
        <MascotSVG />
      </svg>
      {showDecorations && tools.length > 0 && (
        <div className="flex gap-1 mt-1">
          {tools.map(id => {
            const tool = TOOLS[id];
            return tool ? (
              <span key={id} className="text-sm" title={tool.label}>{tool.emoji}</span>
            ) : null;
          })}
        </div>
      )}
    </div>
  );
}

// Helper component for using presets
export function PresetAgentAvatar({ preset, size = 200, className = '' }) {
  const config = AGENT_PRESETS[preset] || AGENT_PRESETS.terminal;
  return (
    <AgentAvatar
      instructions={config.instructions}
      tools={config.tools}
      showDecorations={true}
      size={size}
      className={className}
    />
  );
}
