// Settings → 通用:启动行为与窗口。
//
// The window-position row is here rather than in 外观 for the same reason
// 自动隐藏顶栏 moved out of it: both are about how the window behaves, not
// how it looks. 外观 is themes and type sizes.

import type { ConfigView, StartupModeView } from "../lib/types";
import {
  SettingSection,
  SettingCard,
  SettingChip,
  SettingChips,
  SettingRow,
  type ChipOption,
} from "./ui/SettingControls";

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

const STARTUP_OPTIONS: ReadonlyArray<ChipOption<StartupModeView>> = [
  { value: "resume", label: "智能恢复" },
  { value: "overview", label: "项目总览" },
  { value: "blank", label: "空白" },
];

const LOCALE_OPTIONS: ReadonlyArray<ChipOption<string>> = [
  { value: "zh", label: "简体中文" },
  {
    value: "en",
    label: "English",
    disabledReason: "界面文案目前全部硬编码,还没有接入 i18n 框架",
  },
  {
    value: "system",
    label: "跟随系统",
    disabledReason: "界面文案目前全部硬编码,还没有接入 i18n 框架",
  },
];

export function GeneralSettings({ config, onChange }: Props) {
  return (
    <SettingSection title="通用" lede={<>启动行为与窗口。</>}>
      <SettingCard>
        <SettingRow
          name="启动时打开"
          desc="「智能恢复」= 上次留有活跃会话就直接回工作区,否则进项目总览"
        >
          <SettingChips
            label="启动时打开"
            options={STARTUP_OPTIONS}
            value={config.startup}
            onChange={(startup) => onChange({ ...config, startup })}
          />
        </SettingRow>

        <SettingRow
          name="记住窗口位置与大小"
          desc="退出时记录,下次原样打开"
        >
          {/* Handled by tauri-plugin-window-state at the process level, with
              no runtime switch to expose. Stating that it's on beats an
              always-checked toggle that does nothing when you click it. */}
          <SettingChip tone="on" title="由 tauri-plugin-window-state 在窗口关闭时写入">
            已启用
          </SettingChip>
        </SettingRow>

        {/* 「自动隐藏顶栏」已随顶栏一起移除:全局入口迁到了侧边栏头部
            与画布工具条,没有可隐藏的横条了。config 字段保留兼容老配置。 */}

        <SettingRow
          name="界面语言"
          pendingReason="界面文案目前全部硬编码为简体中文,还没有接入 i18n 框架"
        >
          <SettingChips
            label="界面语言"
            options={LOCALE_OPTIONS}
            value="zh"
            disabled
          />
        </SettingRow>
      </SettingCard>
    </SettingSection>
  );
}
