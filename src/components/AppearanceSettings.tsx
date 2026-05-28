// Font-size editor for the Settings → Appearance section. Mirrors VS Code's
// editor.fontSize / terminal.integrated.fontSize split, with a third lane
// for the UI chrome (sidebar tab strip / file tree / history rows).
//
// Parent owns the staged ConfigView; this component just nudges the
// `font_sizes` slice via `onChange`. The actual apply (CSS var, CodeMirror
// inline style, xterm options.fontSize + fit + PTY resize) happens
// elsewhere on Save — see App.tsx, EditorPanel, TerminalPane, and
// ManualTerminal.

import type { ConfigView, FontSizesView } from "../lib/types";
import { FONT_SIZE_MAX, FONT_SIZE_MIN } from "../lib/store";

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
    </div>
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
