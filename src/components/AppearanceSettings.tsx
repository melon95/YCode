// Settings → Appearance: theme picker + font-size editor.
//
// Parent owns the staged ConfigView; this component just nudges the
// `theme` / `font_sizes` slices via `onChange`. Font sizes are applied on
// Save (the actual CSS-var / xterm fit happens in App.tsx, EditorPanel,
// TerminalPane, ManualTerminal). Theme is *live-previewed* — clicking a
// card writes through to the store immediately so the user sees what
// they're picking. SettingsModal reverts the preview when the dialog is
// closed without saving.

import type { ConfigView, FontSizesView } from "../lib/types";
import { FONT_SIZE_MAX, FONT_SIZE_MIN, useStore } from "../lib/store";
import { THEMES, type Theme } from "../lib/themes";

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

type Lane = keyof FontSizesView;

const LANES: Array<{ key: Lane; label: string; hint: string }> = [
  {
    key: "ui",
    label: "UI",
    hint: "Sidebar history, file tree, right-pane tab strip.",
  },
  {
    key: "editor",
    label: "Editor",
    hint: "CodeMirror code editor in the right pane.",
  },
  {
    key: "terminal",
    label: "Terminal",
    hint: "Main terminal in the middle pane and the right-pane shell.",
  },
];

export function AppearanceSettings({ config, onChange }: Props) {
  const setTheme = useStore((s) => s.setTheme);

  function pickTheme(theme: Theme) {
    onChange({ ...config, theme: theme.id });
    // Live-preview through the store so the chrome and xterm panes re-skin
    // immediately. SettingsModal's discard path reverts this if the user
    // bails without saving.
    setTheme(theme.id);
  }

  function setLane(lane: Lane, raw: string) {
    // Empty input is allowed mid-typing — clamp only on commit (blur).
    // Here we mirror the raw number through so the field is editable; the
    // store's `setFontSizes` re-clamps on Save.
    const parsed = Number(raw);
    const value = Number.isFinite(parsed)
      ? Math.round(parsed)
      : config.font_sizes[lane];
    onChange({
      ...config,
      font_sizes: { ...config.font_sizes, [lane]: value },
    });
  }

  return (
    <div className="appearance-settings">
      <section className="appearance-section">
        <h3 className="appearance-section-title">Theme</h3>
        <p className="settings-section-blurb">
          Switches the chrome palette and the xterm color table in one move.
          Selection is previewed live; close without saving to revert.
        </p>
        <div className="theme-grid">
          {THEMES.map((theme) => (
            <ThemeCard
              key={theme.id}
              theme={theme}
              selected={config.theme === theme.id}
              onSelect={() => pickTheme(theme)}
            />
          ))}
        </div>
      </section>

      <section className="appearance-section">
        <h3 className="appearance-section-title">Font sizes</h3>
        <p className="settings-section-blurb">
          Font sizes apply on Save. The terminal lane re-fits its grid and
          resizes the running PTY in one go — no per-keystroke lag.
        </p>
        {LANES.map((lane) => (
          <Field key={lane.key} label={lane.label} hint={lane.hint}>
            <input
              type="number"
              className="native-input"
              min={FONT_SIZE_MIN}
              max={FONT_SIZE_MAX}
              value={config.font_sizes[lane.key]}
              onChange={(e) => setLane(lane.key, e.target.value)}
            />
          </Field>
        ))}
      </section>
    </div>
  );
}

// Mini swatch + name card. The four color dots come straight out of the
// registry — no curated "marketing" preview — so adding a theme to
// `themes.ts` automatically gives it a card with no extra plumbing.
function ThemeCard({
  theme,
  selected,
  onSelect,
}: {
  theme: Theme;
  selected: boolean;
  onSelect: () => void;
}) {
  const swatches = [
    theme.chrome["--bg"],
    theme.chrome["--panel-raised"],
    theme.chrome["--accent"],
    theme.chrome["--text"],
  ];
  return (
    <button
      type="button"
      className={"theme-card" + (selected ? " selected" : "")}
      aria-pressed={selected}
      onClick={onSelect}
    >
      {selected && (
        <span className="theme-card-active-pill" aria-hidden>
          Active
        </span>
      )}
      <div
        className="theme-card-preview"
        style={{
          background: theme.chrome["--bg"],
          borderColor: theme.chrome["--rule"],
        }}
      >
        <div
          className="theme-card-preview-panel"
          style={{
            background: theme.chrome["--panel"],
            borderColor: theme.chrome["--rule"],
          }}
        >
          <div
            className="theme-card-preview-line"
            style={{ background: theme.chrome["--text-soft"] }}
          />
          <div
            className="theme-card-preview-line short"
            style={{ background: theme.chrome["--muted"] }}
          />
          <div
            className="theme-card-preview-accent"
            style={{ background: theme.chrome["--accent"] }}
          />
        </div>
      </div>
      <div className="theme-card-label">
        <span className="theme-card-name">{theme.label}</span>
        <span className="theme-card-mode">{theme.mode}</span>
      </div>
      <div className="theme-card-swatches" aria-hidden>
        {swatches.map((c, i) => (
          <span
            key={i}
            className="theme-card-swatch"
            style={{ background: c }}
          />
        ))}
      </div>
    </button>
  );
}

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <div className="field">
      <label className="field-label">{label}</label>
      {hint && <div className="field-hint">{hint}</div>}
      {children}
    </div>
  );
}
