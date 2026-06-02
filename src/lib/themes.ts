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
    "--subtle": "#565e72",
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
    "--muted": "#7a6f5a",
    "--subtle": "#9c8f72",
    "--whisper": "#b3a780",

    "--accent": "#c2664a",
    "--accent-soft": "#a8553d",
    "--accent-strong": "#8e4533",
    "--accent-rgb": "194, 102, 74",
    "--accent-tint": "rgba(194, 102, 74, 0.10)",
    "--accent-tint-hover": "rgba(194, 102, 74, 0.18)",

    "--idle": "#8c8167",
    "--running": "#6b8c4f",
    "--running-rgb": "107, 140, 79",
    "--error": "#b04938",
    "--error-rgb": "176, 73, 56",
    "--warning": "#b8893a",
    "--warning-rgb": "184, 137, 58",

    "--diff-add-rgb": "107, 140, 79",
    "--diff-del-rgb": "176, 73, 56",

    "--role-user": "#3e8b85",
    "--role-thinking": "#9a4a8e",
    "--role-tool": "#3d6aa3",
    "--role-plan": "#a87a25",

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
    green: "#5a8042",
    yellow: "#a87a25",
    blue: "#3d6aa3",
    magenta: "#9a4a8e",
    cyan: "#3e8b85",
    white: "#3a3324",
    brightBlack: "#7a6f5a",
    brightRed: "#c25849",
    brightGreen: "#6e9450",
    brightYellow: "#b8893a",
    brightBlue: "#4a7cb8",
    brightMagenta: "#ad599e",
    brightCyan: "#4ba29a",
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
    "--running": "#4a9b6e",
    "--running-rgb": "74, 155, 110",
    "--error": "#c44a4a",
    "--error-rgb": "196, 74, 74",
    "--warning": "#b87a1f",
    "--warning-rgb": "184, 122, 31",

    "--diff-add-rgb": "74, 155, 110",
    "--diff-del-rgb": "196, 74, 74",

    "--role-user": "#2e8a93",
    "--role-thinking": "#9050b3",
    "--role-tool": "#2c5fa8",
    "--role-plan": "#b87a1f",

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
    red: "#c44a4a",
    green: "#3e8a55",
    yellow: "#b87a1f",
    blue: "#4a6dc4",
    magenta: "#9050b3",
    cyan: "#2e8a93",
    white: "#364056",
    brightBlack: "#5b6479",
    brightRed: "#d35858",
    brightGreen: "#4ba068",
    brightYellow: "#c98a30",
    brightBlue: "#5a7fd6",
    brightMagenta: "#a460c4",
    brightCyan: "#3e9da6",
    brightWhite: "#1d2230",
  },
};

export const THEMES: readonly Theme[] = [
  foundry,
  midnight,
  forest,
  parchment,
  daylight,
] as const;
