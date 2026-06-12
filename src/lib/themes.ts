// Theme registry — single source of truth for every palette the app ships.
//
// Each theme bundles two maps:
//   - `chrome`: CSS custom-property values, applied to `:root` inline style.
//     The keys here MUST match the variables `styles.css` reads via `var(…)`
//     for the swap to take effect.
//   - `xterm`: an xterm.js ITheme. TerminalPane and ManualTerminal read this
//     when they boot a Terminal and re-apply it via `term.options.theme = …`
//     whenever the active theme changes.
//
// Adding a theme = appending one entry below. Both halves are required —
// dropping the xterm half would split the chrome and terminal palettes, which
// is the regression we built this registry to avoid.

import type { ITheme as XtermTheme } from "@xterm/xterm";

export type ThemeMode = "dark" | "light";

export interface Theme {
  id: string;
  label: string;
  mode: ThemeMode;
  /// Map of CSS custom property name → value. Names use the leading `--`.
  chrome: Record<string, string>;
  xterm: XtermTheme;
}

export const DEFAULT_THEME_ID = "foundry";

// Singleton <style> element owning the active theme's variables. One
// stylesheet update = one style invalidation pass for the browser, which is
// dramatically cheaper than calling `style.setProperty` ~30 times.
let themeStyleEl: HTMLStyleElement | null = null;

function writeThemeStyle(theme: Theme): void {
  let el = themeStyleEl;
  if (!el) {
    el = document.createElement("style");
    el.id = "ycode-theme-vars";
    document.head.appendChild(el);
    themeStyleEl = el;
  }
  // Build the rule body in one pass. Inlining the join avoids the
  // intermediate string-array allocation for the hot path.
  let body = "";
  for (const key in theme.chrome) {
    body += key + ":" + theme.chrome[key] + ";";
  }
  // `color-scheme` deliberately omitted from this hot path: toggling it on
  // macOS WKWebView signals NSAppearance through the window chrome and
  // forces a multi-pass repaint of every native control on the page
  // (scrollbars, autofill, accent surfaces) — measured in seconds on dense
  // layouts. We set color-scheme statically in `:root` and accept that
  // native scrollbars don't auto-flip when toggling between dark themes
  // and a light theme; users who want a perfectly polished light-mode
  // scrollbar can restart the app after switching.
  el.textContent = `:root{${body}}`;
  const root = document.documentElement;
  root.dataset.theme = theme.id;
  root.dataset.themeMode = theme.mode;
}

/// Apply a theme to `document.documentElement`. One CSSOM write — the
/// per-element transitions and xterm redraws are handled at their own
/// call sites (see `App.tsx` for the store-level subscription, and
/// `TerminalPane.tsx` for the lazy xterm catch-up).
export function applyTheme(theme: Theme): void {
  writeThemeStyle(theme);
}

export function getTheme(id: string): Theme {
  return THEMES.find((t) => t.id === id) ?? THEMES[0];
}

// --- Theme definitions ----------------------------------------------------

// "Foundry" — the launch identity. Warm ink + terracotta. Exact transcription
// of the previous hard-coded `:root` block so existing screenshots/docs keep
// matching after the refactor.
const foundry: Theme = {
  id: "foundry",
  label: "Foundry",
  mode: "dark",
  chrome: {
    "--bg": "#0f0d0a",
    "--surface": "#15120e",
    "--panel": "#191510",
    "--panel-raised": "#211c15",
    "--panel-sunken": "#0b0907",

    "--rule": "#2a221a",
    "--rule-strong": "#3a2f25",
    "--rule-accent": "rgba(217, 119, 87, 0.32)",

    "--text": "#ebe1cf",
    "--text-soft": "#d4c8b3",
    "--muted": "#9e9180",
    "--subtle": "#6a5f51",
    "--whisper": "#3f372d",

    "--accent": "#d97757",
    "--accent-soft": "#e08a6e",
    "--accent-strong": "#ec9576",
    "--accent-rgb": "217, 119, 87",
    "--accent-tint": "rgba(217, 119, 87, 0.08)",
    "--accent-tint-hover": "rgba(217, 119, 87, 0.14)",

    "--idle": "#756d61",
    "--running": "#8aaa6f",
    "--running-rgb": "138, 170, 111",
    "--error": "#d46a5f",
    "--error-rgb": "212, 106, 95",
    "--warning": "#d6a95c",
    "--warning-rgb": "214, 169, 92",

    "--diff-add-rgb": "138, 170, 111",
    "--diff-del-rgb": "201, 119, 112",

    "--role-user": "#7bb8a6",
    "--role-thinking": "#c58fbd",
    "--role-tool": "#8aa4c8",
    "--role-plan": "#efc06f",

    // New tokens. Any literal `rgba(0,0,0,a)` / `rgba(255,255,255,a)` in
    // styles.css has been rewritten to `rgba(var(--shadow-rgb), a)` /
    // `rgba(var(--highlight-rgb), a)` so light themes can flip the polarity.
    "--shadow-rgb": "0, 0, 0",
    "--highlight-rgb": "255, 255, 255",
    "--grain-opacity": "0.025",
    "--grain-blend-mode": "overlay",
    "--vignette-warm": "rgba(217, 119, 87, 0.05)",
    "--vignette-cool": "rgba(120, 80, 200, 0.025)",
    // Selection / focus halo derived from accent — re-declared per theme so
    // each palette can tune intensity instead of inheriting Foundry's bias.
    "--selection-bg": "rgba(217, 119, 87, 0.32)",
    "--accent-glow":
      "0 0 0 1px rgba(217, 119, 87, 0.18), 0 0 24px -8px rgba(217, 119, 87, 0.55)",
    // Text on a filled-accent surface (primary button, hovered menu item).
    // Foundry's terracotta is light enough that dark ink reads better than
    // white — kept as a near-`--bg` warm-black so the brand voice carries.
    "--text-on-accent": "#1a0e08",
  },
  xterm: {
    background: "#13120f",
    foreground: "#f0eee6",
    cursor: "#d97757",
    cursorAccent: "#13120f",
    selectionBackground: "rgba(217, 119, 87, 0.28)",
    black: "#13120f",
    red: "#d46a5f",
    green: "#4caf81",
    yellow: "#d6a95c",
    blue: "#8aa4c8",
    magenta: "#c58fbd",
    cyan: "#7bb8a6",
    white: "#f0eee6",
    brightBlack: "#736b5f",
    brightRed: "#f47670",
    brightGreen: "#6ed09f",
    brightYellow: "#efc06f",
    brightBlue: "#a8bddb",
    brightMagenta: "#d8a8cf",
    brightCyan: "#98d0bf",
    brightWhite: "#fff9ef",
  },
};

// "Midnight" — cool slate-blue dark theme. Accent shifts to a muted azure;
// status colors retreat slightly so the cooler base reads calmly.
const midnight: Theme = {
  id: "midnight",
  label: "Midnight",
  mode: "dark",
  chrome: {
    "--bg": "#0a0e15",
    "--surface": "#0f1320",
    "--panel": "#131826",
    "--panel-raised": "#1b2233",
    "--panel-sunken": "#070a12",

    "--rule": "#1f2738",
    "--rule-strong": "#2d3850",
    "--rule-accent": "rgba(108, 155, 209, 0.32)",

    "--text": "#e2e8f5",
    "--text-soft": "#c5cee0",
    "--muted": "#8a93a8",
    "--subtle": "#5f687d",
    "--whisper": "#2c3245",

    "--accent": "#6c9bd1",
    "--accent-soft": "#85b0df",
    "--accent-strong": "#9bbfe5",
    "--accent-rgb": "108, 155, 209",
    "--accent-tint": "rgba(108, 155, 209, 0.10)",
    "--accent-tint-hover": "rgba(108, 155, 209, 0.18)",

    "--idle": "#5a6378",
    "--running": "#79b885",
    "--running-rgb": "121, 184, 133",
    "--error": "#e07480",
    "--error-rgb": "224, 116, 128",
    "--warning": "#dba656",
    "--warning-rgb": "219, 166, 86",

    "--diff-add-rgb": "121, 184, 133",
    "--diff-del-rgb": "210, 110, 125",

    "--role-user": "#6dbcc4",
    "--role-thinking": "#b58cd6",
    "--role-tool": "#90b8e3",
    "--role-plan": "#ecbe71",

    "--shadow-rgb": "0, 0, 0",
    "--highlight-rgb": "255, 255, 255",
    "--grain-opacity": "0.018",
    "--grain-blend-mode": "overlay",
    "--vignette-warm": "rgba(108, 155, 209, 0.05)",
    "--vignette-cool": "rgba(140, 110, 220, 0.03)",
    "--selection-bg": "rgba(108, 155, 209, 0.30)",
    "--accent-glow":
      "0 0 0 1px rgba(108, 155, 209, 0.22), 0 0 24px -8px rgba(108, 155, 209, 0.55)",
    "--text-on-accent": "#0a0e15",
  },
  xterm: {
    background: "#0f1320",
    foreground: "#e2e8f5",
    cursor: "#6c9bd1",
    cursorAccent: "#0f1320",
    selectionBackground: "rgba(108, 155, 209, 0.28)",
    black: "#0f1320",
    red: "#e07480",
    green: "#79b885",
    yellow: "#dba656",
    blue: "#6c9bd1",
    magenta: "#b58cd6",
    cyan: "#6dbcc4",
    white: "#e2e8f5",
    brightBlack: "#586075",
    brightRed: "#f48f99",
    brightGreen: "#92cf9d",
    brightYellow: "#ecbe71",
    brightBlue: "#90b8e3",
    brightMagenta: "#cba6e8",
    brightCyan: "#86d2da",
    brightWhite: "#f3f6ff",
  },
};

// "Forest" — deep mossy ink with a sage accent. The cooler greens keep the
// chrome readable next to syntax-highlighted code that often leans warm.
const forest: Theme = {
  id: "forest",
  label: "Forest",
  mode: "dark",
  chrome: {
    "--bg": "#0c100c",
    "--surface": "#121712",
    "--panel": "#161c16",
    "--panel-raised": "#1f2820",
    "--panel-sunken": "#080b08",

    "--rule": "#1f2820",
    "--rule-strong": "#2e3a30",
    "--rule-accent": "rgba(136, 168, 106, 0.32)",

    "--text": "#e3ead8",
    "--text-soft": "#c8d3b8",
    "--muted": "#94a087",
    "--subtle": "#5e6856",
    "--whisper": "#353e30",

    "--accent": "#88a86a",
    "--accent-soft": "#9bbe7e",
    "--accent-strong": "#aed18f",
    "--accent-rgb": "136, 168, 106",
    "--accent-tint": "rgba(136, 168, 106, 0.10)",
    "--accent-tint-hover": "rgba(136, 168, 106, 0.18)",

    "--idle": "#6e7864",
    "--running": "#a8c47e",
    "--running-rgb": "168, 196, 126",
    "--error": "#d97070",
    "--error-rgb": "217, 112, 112",
    "--warning": "#d6b25c",
    "--warning-rgb": "214, 178, 92",

    "--diff-add-rgb": "168, 196, 126",
    "--diff-del-rgb": "210, 120, 115",

    "--role-user": "#94d0bf",
    "--role-thinking": "#caa6ca",
    "--role-tool": "#94bcd0",
    "--role-plan": "#e6c473",

    "--shadow-rgb": "0, 0, 0",
    "--highlight-rgb": "245, 250, 230",
    "--grain-opacity": "0.022",
    "--grain-blend-mode": "overlay",
    "--vignette-warm": "rgba(136, 168, 106, 0.05)",
    "--vignette-cool": "rgba(90, 140, 90, 0.025)",
    "--selection-bg": "rgba(136, 168, 106, 0.30)",
    "--accent-glow":
      "0 0 0 1px rgba(136, 168, 106, 0.20), 0 0 24px -8px rgba(136, 168, 106, 0.55)",
    "--text-on-accent": "#0c100c",
  },
  xterm: {
    background: "#121712",
    foreground: "#e3ead8",
    cursor: "#a8c47e",
    cursorAccent: "#121712",
    selectionBackground: "rgba(136, 168, 106, 0.28)",
    black: "#121712",
    red: "#d97070",
    green: "#88a86a",
    yellow: "#d6b25c",
    blue: "#7ba3b8",
    magenta: "#b790b8",
    cyan: "#7bb8a8",
    white: "#e3ead8",
    brightBlack: "#6c7867",
    brightRed: "#ec8585",
    brightGreen: "#a8c47e",
    brightYellow: "#e6c473",
    brightBlue: "#94bcd0",
    brightMagenta: "#caa6ca",
    brightCyan: "#94d0bf",
    brightWhite: "#f5fae6",
  },
};

// "Parchment" — light, warm. Cream paper with the same terracotta family as
// Foundry, so users who like the brand voice but want a light surface can
// switch without losing the editorial accent. Shadows shift to a warm
// near-black so blur halos read as ink, not soot. Paper grain is kept on but
// the blend flips to multiply.
const parchment: Theme = {
  id: "parchment",
  label: "Parchment",
  mode: "light",
  chrome: {
    "--bg": "#f3ecdd",
    "--surface": "#ede5d3",
    "--panel": "#e8e0cc",
    "--panel-raised": "#f6f0e1",
    "--panel-sunken": "#dcd2b9",

    "--rule": "#cabf9f",
    "--rule-strong": "#a89c7a",
    "--rule-accent": "rgba(194, 102, 74, 0.36)",

    "--text": "#2a241a",
    "--text-soft": "#4a402e",
    "--muted": "#5e553f",
    "--subtle": "#857862",
    "--whisper": "#b3a780",

    "--accent": "#c2664a",
    "--accent-soft": "#a8553d",
    "--accent-strong": "#8e4533",
    "--accent-rgb": "194, 102, 74",
    "--accent-tint": "rgba(194, 102, 74, 0.10)",
    "--accent-tint-hover": "rgba(194, 102, 74, 0.18)",

    "--idle": "#8c8167",
    "--running": "#4a6a32",
    "--running-rgb": "74, 106, 50",
    "--error": "#b04938",
    "--error-rgb": "176, 73, 56",
    "--warning": "#7a5410",
    "--warning-rgb": "122, 84, 16",

    "--diff-add-rgb": "74, 106, 50",
    "--diff-del-rgb": "176, 73, 56",

    "--role-user": "#1d6562",
    "--role-thinking": "#9a4a8e",
    "--role-tool": "#3d6aa3",
    "--role-plan": "#7a5410",

    "--shadow-rgb": "60, 45, 25",
    "--highlight-rgb": "255, 250, 235",
    "--grain-opacity": "0.04",
    "--grain-blend-mode": "multiply",
    "--vignette-warm": "rgba(194, 102, 74, 0.06)",
    "--vignette-cool": "rgba(120, 80, 40, 0.04)",
    "--selection-bg": "rgba(194, 102, 74, 0.28)",
    "--accent-glow":
      "0 0 0 1px rgba(194, 102, 74, 0.30), 0 0 24px -8px rgba(194, 102, 74, 0.45)",
    "--text-on-accent": "#ffffff",
  },
  xterm: {
    background: "#f3ecdd",
    foreground: "#2a241a",
    cursor: "#c2664a",
    cursorAccent: "#f3ecdd",
    selectionBackground: "rgba(194, 102, 74, 0.32)",
    black: "#2a241a",
    red: "#b04938",
    green: "#456533",
    yellow: "#7a5410",
    blue: "#3d6aa3",
    magenta: "#9a4a8e",
    cyan: "#1d6562",
    white: "#3a3324",
    brightBlack: "#7a6f5a",
    brightRed: "#9a2e22",
    brightGreen: "#456533",
    brightYellow: "#7a5410",
    brightBlue: "#2c548c",
    brightMagenta: "#7e3270",
    brightCyan: "#246e68",
    brightWhite: "#2a241a",
  },
};

// "Daylight" — clean, cool, neutral light. The choice for users who want
// VS Code-light energy: muted indigo accent, restrained vignette, paper
// grain disabled (it reads as smudge on cool surfaces).
const daylight: Theme = {
  id: "daylight",
  label: "Daylight",
  mode: "light",
  chrome: {
    "--bg": "#f4f5f7",
    "--surface": "#ebedf1",
    "--panel": "#e3e6ec",
    "--panel-raised": "#f8f9fb",
    "--panel-sunken": "#d6dae3",

    "--rule": "#c5c9d2",
    "--rule-strong": "#a0a6b3",
    "--rule-accent": "rgba(74, 109, 196, 0.34)",

    "--text": "#1d2230",
    "--text-soft": "#364056",
    "--muted": "#5b6479",
    "--subtle": "#818a9d",
    "--whisper": "#aab1bf",

    "--accent": "#4a6dc4",
    "--accent-soft": "#3d5cab",
    "--accent-strong": "#324d92",
    "--accent-rgb": "74, 109, 196",
    "--accent-tint": "rgba(74, 109, 196, 0.10)",
    "--accent-tint-hover": "rgba(74, 109, 196, 0.18)",

    "--idle": "#818a9d",
    "--running": "#1f6d3f",
    "--running-rgb": "31, 109, 63",
    "--error": "#a52828",
    "--error-rgb": "165, 40, 40",
    "--warning": "#7e5008",
    "--warning-rgb": "126, 80, 8",

    "--diff-add-rgb": "31, 109, 63",
    "--diff-del-rgb": "165, 40, 40",

    "--role-user": "#175e68",
    "--role-thinking": "#9050b3",
    "--role-tool": "#2c5fa8",
    "--role-plan": "#7e5008",

    "--shadow-rgb": "30, 38, 56",
    "--highlight-rgb": "255, 255, 255",
    "--grain-opacity": "0",
    "--grain-blend-mode": "normal",
    "--vignette-warm": "rgba(74, 109, 196, 0.05)",
    "--vignette-cool": "rgba(120, 100, 200, 0.03)",
    "--selection-bg": "rgba(74, 109, 196, 0.24)",
    "--accent-glow":
      "0 0 0 1px rgba(74, 109, 196, 0.28), 0 0 24px -8px rgba(74, 109, 196, 0.45)",
    "--text-on-accent": "#ffffff",
  },
  xterm: {
    background: "#f4f5f7",
    foreground: "#1d2230",
    cursor: "#4a6dc4",
    cursorAccent: "#f4f5f7",
    selectionBackground: "rgba(74, 109, 196, 0.28)",
    black: "#1d2230",
    red: "#a52828",
    green: "#1f6d3f",
    yellow: "#7e5008",
    blue: "#4a6dc4",
    magenta: "#9050b3",
    cyan: "#175e68",
    white: "#364056",
    brightBlack: "#5b6479",
    brightRed: "#b03030",
    brightGreen: "#2d7a4d",
    brightYellow: "#925e0e",
    brightBlue: "#3554a8",
    brightMagenta: "#7a3a92",
    brightCyan: "#1f7078",
    brightWhite: "#1d2230",
  },
};

// "Synapse" — neon-cyberpunk dark. Near-OLED ink, electric magenta accent,
// cyan secondary signals. Grain blend flips to `screen` so the highlight
// flecks read as glow on a true-black canvas instead of dust.
const synapse: Theme = {
  id: "synapse",
  label: "Synapse",
  mode: "dark",
  chrome: {
    "--bg": "#08060f",
    "--surface": "#0e0b1a",
    "--panel": "#141027",
    "--panel-raised": "#1d1838",
    "--panel-sunken": "#05030c",

    "--rule": "#241c44",
    "--rule-strong": "#372c63",
    "--rule-accent": "rgba(217, 70, 239, 0.42)",

    "--text": "#f0e8ff",
    "--text-soft": "#d4c8eb",
    "--muted": "#9088b4",
    "--subtle": "#5e5786",
    "--whisper": "#352e4f",

    "--accent": "#d946ef",
    "--accent-soft": "#e768f5",
    "--accent-strong": "#f085fb",
    "--accent-rgb": "217, 70, 239",
    "--accent-tint": "rgba(217, 70, 239, 0.10)",
    "--accent-tint-hover": "rgba(217, 70, 239, 0.18)",

    "--idle": "#5e5786",
    "--running": "#3ee8c8",
    "--running-rgb": "62, 232, 200",
    "--error": "#ff4d80",
    "--error-rgb": "255, 77, 128",
    "--warning": "#ffb648",
    "--warning-rgb": "255, 182, 72",

    "--diff-add-rgb": "62, 232, 200",
    "--diff-del-rgb": "255, 77, 128",

    "--role-user": "#5be0ff",
    "--role-thinking": "#d946ef",
    "--role-tool": "#a78bfa",
    "--role-plan": "#ffd84d",

    "--shadow-rgb": "0, 0, 0",
    "--highlight-rgb": "255, 230, 255",
    "--grain-opacity": "0.018",
    "--grain-blend-mode": "screen",
    "--vignette-warm": "rgba(217, 70, 239, 0.06)",
    "--vignette-cool": "rgba(91, 224, 255, 0.04)",
    "--selection-bg": "rgba(217, 70, 239, 0.34)",
    "--accent-glow":
      "0 0 0 1px rgba(217, 70, 239, 0.26), 0 0 28px -6px rgba(217, 70, 239, 0.70)",
    "--text-on-accent": "#0a0710",
  },
  xterm: {
    background: "#0e0b1a",
    foreground: "#f0e8ff",
    cursor: "#d946ef",
    cursorAccent: "#0e0b1a",
    selectionBackground: "rgba(217, 70, 239, 0.30)",
    black: "#0e0b1a",
    red: "#ff4d80",
    green: "#3ee8c8",
    yellow: "#ffd84d",
    blue: "#7c9eff",
    magenta: "#d946ef",
    cyan: "#5be0ff",
    white: "#f0e8ff",
    brightBlack: "#5e5786",
    brightRed: "#ff7095",
    brightGreen: "#6ff5d8",
    brightYellow: "#ffe680",
    brightBlue: "#a3baff",
    brightMagenta: "#e768f5",
    brightCyan: "#82e8ff",
    brightWhite: "#fff5ff",
  },
};

// "Lagoon" — soft, low-contrast dark. Deep teal-ink canvas with a muted
// seafoam accent. Reduced text-to-background contrast (≈10:1 instead of
// Foundry's ≈14:1) so long sessions don't burn the eyes; status colors
// pull back from saturated into mineral tones to match.
const lagoon: Theme = {
  id: "lagoon",
  label: "Lagoon",
  mode: "dark",
  chrome: {
    "--bg": "#0d1518",
    "--surface": "#121b1f",
    "--panel": "#162127",
    "--panel-raised": "#1d2b32",
    "--panel-sunken": "#0a1012",

    "--rule": "#1f2c33",
    "--rule-strong": "#2f3f48",
    "--rule-accent": "rgba(110, 180, 175, 0.30)",

    "--text": "#cfdde0",
    "--text-soft": "#b3c3c6",
    "--muted": "#7d8e91",
    "--subtle": "#5e6c70",
    "--whisper": "#2f3a3e",

    "--accent": "#6eb4af",
    "--accent-soft": "#83c5c0",
    "--accent-strong": "#98d4cf",
    "--accent-rgb": "110, 180, 175",
    "--accent-tint": "rgba(110, 180, 175, 0.08)",
    "--accent-tint-hover": "rgba(110, 180, 175, 0.14)",

    "--idle": "#5c6a6d",
    "--running": "#7eb288",
    "--running-rgb": "126, 178, 136",
    "--error": "#cc7878",
    "--error-rgb": "204, 120, 120",
    "--warning": "#c4a060",
    "--warning-rgb": "196, 160, 96",

    "--diff-add-rgb": "126, 178, 136",
    "--diff-del-rgb": "204, 120, 120",

    "--role-user": "#7ec2bd",
    "--role-thinking": "#a392c4",
    "--role-tool": "#7da4c2",
    "--role-plan": "#ccb074",

    "--shadow-rgb": "0, 0, 0",
    "--highlight-rgb": "200, 230, 230",
    "--grain-opacity": "0.015",
    "--grain-blend-mode": "overlay",
    "--vignette-warm": "rgba(110, 180, 175, 0.04)",
    "--vignette-cool": "rgba(80, 140, 160, 0.03)",
    "--selection-bg": "rgba(110, 180, 175, 0.24)",
    "--accent-glow":
      "0 0 0 1px rgba(110, 180, 175, 0.16), 0 0 20px -8px rgba(110, 180, 175, 0.40)",
    "--text-on-accent": "#0d1518",
  },
  xterm: {
    background: "#121b1f",
    foreground: "#cfdde0",
    cursor: "#6eb4af",
    cursorAccent: "#121b1f",
    selectionBackground: "rgba(110, 180, 175, 0.22)",
    black: "#121b1f",
    red: "#cc7878",
    green: "#7eb288",
    yellow: "#c4a060",
    blue: "#7da4c2",
    magenta: "#a392c4",
    cyan: "#6eb4af",
    white: "#cfdde0",
    brightBlack: "#5e6a6d",
    brightRed: "#d98c8c",
    brightGreen: "#92c499",
    brightYellow: "#d4b478",
    brightBlue: "#92b8d4",
    brightMagenta: "#b6a6d4",
    brightCyan: "#82c5c0",
    brightWhite: "#e6f0f2",
  },
};

// "Linen" — high-contrast light. Paper-white surface with near-black ink
// and a deep cobalt accent. Every foreground token sits above WCAG AA
// against the panel backgrounds, including the muted/subtle tier, so
// secondary copy stays legible in bright rooms. No grain.
const linen: Theme = {
  id: "linen",
  label: "Linen",
  mode: "light",
  chrome: {
    "--bg": "#fbfaf6",
    "--surface": "#f4f2ec",
    "--panel": "#ecebe5",
    "--panel-raised": "#ffffff",
    "--panel-sunken": "#e0ddd3",

    "--rule": "#bcb7a8",
    "--rule-strong": "#857f6e",
    "--rule-accent": "rgba(29, 78, 216, 0.42)",

    "--text": "#0c0c08",
    "--text-soft": "#26241d",
    "--muted": "#4a4738",
    "--subtle": "#6a6655",
    "--whisper": "#a09c8a",

    "--accent": "#1d4ed8",
    "--accent-soft": "#1640b6",
    "--accent-strong": "#0e3091",
    "--accent-rgb": "29, 78, 216",
    "--accent-tint": "rgba(29, 78, 216, 0.10)",
    "--accent-tint-hover": "rgba(29, 78, 216, 0.18)",

    "--idle": "#6a6655",
    "--running": "#1f7a3e",
    "--running-rgb": "31, 122, 62",
    "--error": "#a51c1c",
    "--error-rgb": "165, 28, 28",
    "--warning": "#955a05",
    "--warning-rgb": "149, 90, 5",

    "--diff-add-rgb": "31, 122, 62",
    "--diff-del-rgb": "165, 28, 28",

    "--role-user": "#0f6e6a",
    "--role-thinking": "#7a1d92",
    "--role-tool": "#1d4ed8",
    "--role-plan": "#955a05",

    "--shadow-rgb": "20, 18, 10",
    "--highlight-rgb": "255, 255, 255",
    "--grain-opacity": "0",
    "--grain-blend-mode": "normal",
    "--vignette-warm": "rgba(29, 78, 216, 0.03)",
    "--vignette-cool": "rgba(80, 60, 200, 0.02)",
    "--selection-bg": "rgba(29, 78, 216, 0.22)",
    "--accent-glow":
      "0 0 0 1px rgba(29, 78, 216, 0.30), 0 0 20px -8px rgba(29, 78, 216, 0.50)",
    "--text-on-accent": "#ffffff",
  },
  xterm: {
    background: "#fbfaf6",
    foreground: "#0c0c08",
    cursor: "#1d4ed8",
    cursorAccent: "#fbfaf6",
    selectionBackground: "rgba(29, 78, 216, 0.26)",
    black: "#0c0c08",
    red: "#a51c1c",
    green: "#1f7a3e",
    yellow: "#955a05",
    blue: "#1d4ed8",
    magenta: "#7a1d92",
    cyan: "#0f6e6a",
    white: "#26241d",
    brightBlack: "#4a4738",
    brightRed: "#b91c1c",
    brightGreen: "#1f7a3e",
    brightYellow: "#955a05",
    brightBlue: "#2a5fe5",
    brightMagenta: "#902aa8",
    brightCyan: "#168078",
    brightWhite: "#0c0c08",
  },
};

// "Glacier" — soft, cool light. Faintly blue paper with a glacier-teal
// accent. Sits between Daylight's neutral indigo and a true ice-blue
// theme — calmer than Daylight, but still unmistakably cool.
const glacier: Theme = {
  id: "glacier",
  label: "Glacier",
  mode: "light",
  chrome: {
    "--bg": "#eef3f7",
    "--surface": "#e4ebf1",
    "--panel": "#dae3eb",
    "--panel-raised": "#f4f8fc",
    "--panel-sunken": "#ccd6e0",

    "--rule": "#b8c4d0",
    "--rule-strong": "#8b97a4",
    "--rule-accent": "rgba(58, 130, 170, 0.32)",

    "--text": "#1a2733",
    "--text-soft": "#324554",
    "--muted": "#4a5b68",
    "--subtle": "#7e8d9b",
    "--whisper": "#a7b3bf",

    "--accent": "#1f547a",
    "--accent-soft": "#1a486a",
    "--accent-strong": "#143a58",
    "--accent-rgb": "31, 84, 122",
    "--accent-tint": "rgba(31, 84, 122, 0.10)",
    "--accent-tint-hover": "rgba(31, 84, 122, 0.18)",

    "--idle": "#7e8d9b",
    "--running": "#1e6354",
    "--running-rgb": "30, 99, 84",
    "--error": "#a02838",
    "--error-rgb": "160, 40, 56",
    "--warning": "#7a5008",
    "--warning-rgb": "122, 80, 8",

    "--diff-add-rgb": "30, 99, 84",
    "--diff-del-rgb": "160, 40, 56",

    "--role-user": "#125862",
    "--role-thinking": "#7a4f9c",
    "--role-tool": "#356d9c",
    "--role-plan": "#7a5008",

    "--shadow-rgb": "30, 50, 70",
    "--highlight-rgb": "255, 255, 255",
    "--grain-opacity": "0",
    "--grain-blend-mode": "normal",
    "--vignette-warm": "rgba(31, 84, 122, 0.04)",
    "--vignette-cool": "rgba(90, 140, 200, 0.03)",
    "--selection-bg": "rgba(31, 84, 122, 0.22)",
    "--accent-glow":
      "0 0 0 1px rgba(31, 84, 122, 0.26), 0 0 20px -8px rgba(31, 84, 122, 0.42)",
    "--text-on-accent": "#ffffff",
  },
  xterm: {
    background: "#eef3f7",
    foreground: "#1a2733",
    cursor: "#1f547a",
    cursorAccent: "#eef3f7",
    selectionBackground: "rgba(31, 84, 122, 0.26)",
    black: "#1a2733",
    red: "#a02838",
    green: "#1e6354",
    yellow: "#7a5008",
    blue: "#1f547a",
    magenta: "#7a4f9c",
    cyan: "#125862",
    white: "#324554",
    brightBlack: "#4a5b68",
    brightRed: "#a83545",
    brightGreen: "#266d5e",
    brightYellow: "#7e5510",
    brightBlue: "#266a92",
    brightMagenta: "#6e4490",
    brightCyan: "#176660",
    brightWhite: "#1a2733",
  },
};

export const THEMES: readonly Theme[] = [
  foundry,
  midnight,
  forest,
  synapse,
  lagoon,
  parchment,
  daylight,
  linen,
  glacier,
] as const;
