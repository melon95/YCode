// Settings → Appearance: theme picker, top-bar behavior, font-size editor.
//
// Parent owns the staged ConfigView; this component just nudges the
// `theme` / `auto_hide_top_bar` / `font_sizes` slices via `onChange`. Font
// sizes and the top-bar toggle are applied on Save (the actual CSS-var /
// xterm fit happens in App.tsx, EditorPanel,
// TerminalPane, ManualTerminal). Theme is *live-previewed* — clicking a
// card writes through to the store immediately so the user sees what
// they're picking. SettingsModal reverts the preview when the dialog is
// closed without saving.

import type { ConfigView, FontSizesView } from "../lib/types";
import { FONT_SIZE_MAX, FONT_SIZE_MIN, useStore } from "../lib/store";
import { THEMES, type Theme, type ThemeMode } from "../lib/themes";

// Themes split into Light / Dark lanes (Light first) so the picker reads as
// two short lists instead of one long mixed grid. Order within each lane
// follows the registry's declaration order.
const THEME_GROUPS: Array<{ mode: ThemeMode; label: string }> = [
  { mode: "light", label: "Light" },
  { mode: "dark", label: "Dark" },
];

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
        {THEME_GROUPS.map((group) => {
          const themes = THEMES.filter((t) => t.mode === group.mode);
          if (themes.length === 0) return null;
          return (
            <div className="theme-group" key={group.mode}>
              <div className="theme-group-label">{group.label}</div>
              <div className="theme-grid">
                {themes.map((theme) => (
                  <ThemeCard
                    key={theme.id}
                    theme={theme}
                    selected={config.theme === theme.id}
                    onSelect={() => pickTheme(theme)}
                  />
                ))}
              </div>
            </div>
          );
        })}
      </section>

      <section className="appearance-section">
        <h3 className="appearance-section-title">Top bar</h3>
        <p className="settings-section-blurb">
          The top bar holds the project tabs, search, and this settings gear.
        </p>
        <Field
          label="Auto-hide the top bar"
          hint="Collapses the bar and hands its 44px to the workspace. Move the pointer to the very top of the window to slide it back over the content. ⌘K and ⌘O keep working while it's hidden."
        >
          <input
            type="checkbox"
            checked={config.auto_hide_top_bar}
            onChange={(e) =>
              onChange({ ...config, auto_hide_top_bar: e.target.checked })
            }
          />
        </Field>
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
