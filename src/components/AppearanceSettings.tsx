// Settings → 外观:主题与字号。
//
// The top-bar toggle used to live here; it moved to 通用 because hiding a
// bar is window behaviour, not a look. What's left is genuinely visual.
//
// Parent owns the staged ConfigView; this component just nudges the
// `theme` / `font_sizes` slices via `onChange`. Font sizes apply on Save
// (the actual CSS-var / xterm fit happens in App.tsx, EditorPanel,
// TerminalPane, ManualTerminal). Theme is *live-previewed* — clicking a
// card writes through to the store immediately so the user sees what
// they're picking. SettingsModal reverts the preview when the dialog is
// closed without saving.

import type { ConfigView, FontSizesView } from "../lib/types";
import { useStore } from "../lib/store";
import {
  getTheme,
  MODE_THEME_ID,
  prefersDark,
  SYSTEM_THEME_ID,
  themeChoice,
  type Theme,
} from "../lib/themes";
import {
  SettingSection,
  SettingCard,
  SettingChip,
  SettingChips,
  SettingGroupLabel,
  SettingNote,
  SettingRow,
  type ChipOption,
} from "./ui/SettingControls";

// Three cards, matching the preview. The registry still ships ten themes and
// a config naming any of them still loads — but ten swatches asked the user
// to pick between five greys, which is a decision the app should be making
// for them. 跟随系统 previews whichever side the OS is on right now.
const CHOICES: Array<{
  choice: "light" | "dark" | "system";
  label: string;
  preview: () => Theme;
}> = [
  { choice: "light", label: "浅色", preview: () => getTheme(MODE_THEME_ID.light) },
  { choice: "dark", label: "深色", preview: () => getTheme(MODE_THEME_ID.dark) },
  {
    choice: "system",
    label: "跟随系统",
    preview: () => getTheme(MODE_THEME_ID[prefersDark() ? "dark" : "light"]),
  },
];

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

type Lane = keyof FontSizesView;

const LANES: Array<{ key: Lane; label: string; hint: string }> = [
  {
    key: "ui",
    label: "界面",
    hint: "侧边栏、文件树、右栏标签条",
  },
  {
    key: "editor",
    label: "编辑器",
    hint: "右栏的 CodeMirror 代码编辑器",
  },
  {
    key: "terminal",
    label: "终端",
    hint: "中栏的 agent 终端与右栏的手动终端",
  },
];

/// The same four steps the terminal page offers. A numeric input let you
/// type 9 or 40 and then wonder why the app looked broken; the sizes people
/// actually want are a short list.
const SIZE_OPTIONS: ReadonlyArray<ChipOption<string>> = [
  { value: "12", label: "12" },
  { value: "13", label: "13" },
  { value: "14", label: "14" },
  { value: "15", label: "15" },
];

/// store 仍接受 8–32,老配置里可能存着 16 这类不在预设里的值。直接渲染
/// 四个预设会让当前值既不可见也没有选中态,一碰就被压回 12–15。所以当
/// 前值不在预设里时,在末尾追加一个「16(当前)」chip 保住它 —— 只有
/// 用户主动点了别的 chip 才切换,不静默丢值。
function sizeOptionsFor(current: number): ReadonlyArray<ChipOption<string>> {
  const value = String(current);
  if (SIZE_OPTIONS.some((o) => o.value === value)) return SIZE_OPTIONS;
  return [...SIZE_OPTIONS, { value, label: `${value}(当前)` }];
}

export function AppearanceSettings({ config, onChange }: Props) {
  const setTheme = useStore((s) => s.setTheme);

  const choice = themeChoice(config.theme);

  function pick(next: "light" | "dark" | "system") {
    const id = next === "system" ? SYSTEM_THEME_ID : MODE_THEME_ID[next];
    onChange({ ...config, theme: id });
    // Live-preview through the store so the chrome and xterm panes re-skin
    // immediately. SettingsModal's discard path reverts this if the user
    // bails without saving.
    setTheme(id);
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
    <SettingSection
      title="外观"
      lede={
        <>
  主题会同时换掉界面配色和终端的 xterm 色表。选中即时预览,不保存直接关闭
          就还原。
        </>
      }
    >
      <SettingGroupLabel>主题</SettingGroupLabel>
      {/* Three cards, one row. The old grid was `auto-fill minmax(150px)` for
          ten themes; with three named choices they should sit side by side
          rather than reflow into a ragged block. */}
      <div className="grid grid-cols-3 gap-2.5 mt-1">
        {CHOICES.map((c) => (
          <ThemeCard
            key={c.choice}
            label={c.label}
            theme={c.preview()}
            split={c.choice === "system"}
            selected={choice === c.choice}
            onSelect={() => pick(c.choice)}
          />
        ))}
      </div>

      <SettingGroupLabel className="settings-group-gap">布局</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="界面密度"
          desc="紧凑挤进更多会话行,宽松留更多呼吸空间"
          pendingReason="密度令牌未接入,全局间距目前固定"
        >
          <SettingChips
            label="界面密度"
            options={[
              { value: "compact", label: "紧凑" },
              { value: "standard", label: "标准" },
              { value: "relaxed", label: "宽松" },
            ]}
            value="standard"
            disabled
          />
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel className="settings-group-gap">字号</SettingGroupLabel>
      <SettingCard>
        {LANES.map((lane) => (
          <SettingRow key={lane.key} name={lane.label} desc={lane.hint}>
            <SettingChips
              label={`${lane.label}字号`}
              options={sizeOptionsFor(config.font_sizes[lane.key])}
              value={String(config.font_sizes[lane.key])}
              onChange={(v) => setLane(lane.key, v)}
            />
          </SettingRow>
        ))}
      </SettingCard>
      <SettingNote>
        字号在保存时生效。终端会重新计算网格并同步调整正在运行的 PTY,
        不会逐字卡顿。
      </SettingNote>

      <SettingGroupLabel>动效</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="减少动态效果"
          desc="跟随系统的辅助功能设置,开启后状态点不再呼吸、弹层不再位移"
        >
          <SettingChip tone="on" title="通过 prefers-reduced-motion 媒体查询生效">
            跟随系统
          </SettingChip>
        </SettingRow>
      </SettingCard>
    </SettingSection>
  );
}

/// A mock window in the theme's own colours. The card is named for the
/// *choice* (浅色 / 深色 / 跟随系统) rather than the theme's brand name —
/// which theme backs each mode is an implementation detail now.
function ThemeCard({
  theme,
  label,
  split,
  selected,
  onSelect,
}: {
  theme: Theme;
  label: string;
  /// The 跟随系统 card, which says what the OS currently resolves to instead
  /// of pretending to be a fixed palette.
  split?: boolean;
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
      // 选中态是两层描边:实心 accent 环 + 更宽的半透明光晕。光晕用 22% ——
      // 不是全局的 8% tint —— 才能在每种表面上都读得出来:Foundry 的暖暗、
      // Daylight 的近白、Parchment 的暖亮都一样。
      className={`relative flex flex-col gap-2 p-[9px] border rounded-md cursor-pointer
        text-left font-[inherit] text-text
        transition-[border-color,background,transform] duration-[var(--duration-fast)] ease-out
        active:translate-y-px ${
          selected
            ? "border-accent bg-panel-raised [box-shadow:0_0_0_1px_var(--accent),0_0_0_5px_var(--color-accent-halo)]"
            : "border-rule bg-panel hover:border-rule-strong hover:bg-panel-raised"
        }`
        .replace(/\s+/g, " ")
        .trim()}
      aria-pressed={selected}
      onClick={onSelect}
    >
      {selected && (
        <span
          className="absolute top-1.5 right-1.5 inline-flex items-center gap-[3px]
            pt-0.5 pr-1.5 pb-0.5 pl-1 bg-accent text-on-accent font-ui text-[9px] font-semibold
            tracking-[0.06em] uppercase rounded-[3px] pointer-events-none
            before:content-['✓'] before:text-[10px] before:leading-none"
          aria-hidden
        >
          当前
        </span>
      )}
      {/* The card preview is a tiny abstract "ycode in miniature" — a body
          color with an inset panel and two text rules plus a small accent
          block. It's intentionally agnostic of the real layout; we want users
          to read the *palette*, not memorize the chrome arrangement. */}
      <div
        className="relative h-16 border rounded-[4px] overflow-hidden"
        style={{
          background: theme.chrome["--bg"],
          borderColor: theme.chrome["--rule"],
        }}
      >
        <div
          className="absolute inset-y-2 right-2 left-7 p-1.5 border rounded-[3px] flex flex-col gap-1"
          style={{
            background: theme.chrome["--panel"],
            borderColor: theme.chrome["--rule"],
          }}
        >
          <div
            className="h-[3px] w-4/5 rounded-[1px] opacity-85"
            style={{ background: theme.chrome["--text-soft"] }}
          />
          <div
            className="h-[3px] w-1/2 rounded-[1px] opacity-55"
            style={{ background: theme.chrome["--muted"] }}
          />
          <div
            className="absolute left-1 top-1 bottom-1 w-1 rounded-[2px]"
            style={{ background: theme.chrome["--accent"] }}
          />
        </div>
      </div>
      {/* The label row keeps its height whether or not the mode caption is
          there, so the three cards stay the same size. */}
      <div className="flex items-baseline justify-between gap-1.5 min-h-[18px]">
        <span className="font-ui text-[14px] font-medium tracking-[-0.01em]">
          {label}
        </span>
        <span className="font-mono text-[9px] text-muted">
          {split ? (theme.mode === "dark" ? "当前:深色" : "当前:浅色") : ""}
        </span>
      </div>
      <div className="flex gap-1" aria-hidden>
        {swatches.map((c, i) => (
          <span
            key={i}
            className="flex-1 h-1.5 rounded-[2px] border border-[rgba(var(--shadow-rgb),0.12)]"
            style={{ background: c }}
          />
        ))}
      </div>
    </button>
  );
}
