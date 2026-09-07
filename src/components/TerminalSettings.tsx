// Settings → 终端:agent 与 shell 跑在什么环境里。
//
// This nav entry used to open the `ycode` shell-command installer, which is
// a different thing entirely (that now lives in 集成). What belongs here is
// the terminal itself — and of the preview's rows, the font size is the one
// with real backing: `font_sizes.terminal` already drives every xterm.js
// instance. The rest describes what ycode does today so the page answers
// "which shell is my agent actually running in" rather than pretending to
// let you change it.

import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { i18next } from "../lib/i18n";
import { platform } from "@tauri-apps/plugin-os";
import type { ConfigView } from "../lib/types";
import {
  SettingSection,
  SettingAction,
  SettingCard,
  SettingChip,
  SettingChips,
  SettingGroupLabel,
  SettingRow,
  SettingValue,
  type ChipOption,
} from "./ui/SettingControls";

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

const SIZE_OPTIONS: ReadonlyArray<ChipOption<string>> = [
  { value: "12", label: "12" },
  { value: "13", label: "13" },
  { value: "14", label: "14" },
  { value: "15", label: "15" },
];

/// store 仍接受 8–32,老配置里可能存着 16 这类不在预设里的值。当前值不在
/// 预设里时,在末尾追加一个「16(当前)」chip 保住它 —— 只有用户主动点了
/// 别的 chip 才切换,不静默丢值。与外观页的处理保持一致。
function sizeOptionsFor(current: number): ReadonlyArray<ChipOption<string>> {
  const value = String(current);
  if (SIZE_OPTIONS.some((o) => o.value === value)) return SIZE_OPTIONS;
  return [
    ...SIZE_OPTIONS,
    { value, label: i18next.t("settings.appearance.currentValue", { value }) },
  ];
}

export function TerminalSettings({ config, onChange }: Props) {
  const { t } = useTranslation();
  const [shell, setShell] = useState<string | null>(null);

  useEffect(() => {
    // The backend spawns the user's login shell; read the same env var it
    // does so the row shows the real value rather than a guess.
    try {
      const os = platform();
      setShell(os === "windows" ? "powershell.exe" : "$SHELL -l");
    } catch {
      setShell(null);
    }
  }, []);

  return (
    <SettingSection
      title={t("settings.terminal.title")}
      lede={<>{t("settings.terminal.lede")}</>}
    >
      <SettingGroupLabel>{t("settings.terminal.environment")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="Shell"
          desc={t("settings.terminal.loginShellDesc")}
        >
          <SettingValue align="end">{shell ?? "—"}</SettingValue>
          {/* 只读展示是真的;能改是假的 —— 按钮保留位置但按待实现处理,
              原因放在 tooltip 里,而不是整行灰掉把真实信息也一起灰掉。 */}
          <SettingAction
            label={t("settings.terminal.changeShell")}
            disabled
            title={t("settings.terminal.changeShellPending")}
          >
            <EditIcon />
          </SettingAction>
        </SettingRow>
        <SettingRow
          name={t("settings.terminal.cwd")}
          desc={t("settings.terminal.cwdDesc")}
        >
          <SettingChip tone="on">{t("settings.terminal.perSession")}</SettingChip>
        </SettingRow>
        <SettingRow
          name={t("settings.terminal.envVars")}
          desc={t("settings.terminal.envVarsDesc")}
        >
          <SettingChip>{t("settings.terminal.seeAgents")}</SettingChip>
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>{t("settings.terminal.display")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.terminal.font")}
          desc={t("settings.terminal.fontDesc")}
          pendingReason={t("settings.terminal.fontPending")}
        >
          <SettingValue align="end">ui-monospace</SettingValue>
        </SettingRow>
        <SettingRow
          name={t("settings.terminal.fontSize")}
          desc={t("settings.terminal.fontSizeDesc")}
        >
          <SettingChips
            label={t("settings.terminal.terminalFontSize")}
            options={sizeOptionsFor(config.font_sizes.terminal)}
            value={String(config.font_sizes.terminal)}
            onChange={(v) =>
              onChange({
                ...config,
                font_sizes: { ...config.font_sizes, terminal: Number(v) },
              })
            }
          />
        </SettingRow>
        <SettingRow
          name={t("settings.terminal.themeFollows")}
          desc={t("settings.terminal.themeFollowsDesc")}
        >
          <SettingChip tone="on">{t("common.enabled")}</SettingChip>
        </SettingRow>
        <SettingRow
          name={t("settings.terminal.scrollback")}
          desc={t("settings.terminal.scrollbackDesc")}
        >
          <SettingValue align="end">256 KB</SettingValue>
        </SettingRow>
        <SettingRow
          name={t("settings.terminal.renderer")}
          desc={t("settings.terminal.rendererDesc")}
        >
          <SettingChip tone="on">WebGL</SettingChip>
        </SettingRow>
      </SettingCard>
    </SettingSection>
  );
}

function EditIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z" />
    </svg>
  );
}
